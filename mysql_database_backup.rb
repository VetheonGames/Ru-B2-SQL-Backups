# frozen_string_literal: true

require 'json'
require_relative 'loggman'

# class for creating, managing and deleting backups both locally and in B2
class MysqlDatabaseBackup
  def initialize(config_file, logger) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    config = JSON.parse(File.read(config_file))
    @host = config['mysql']['host']
    @username = config['mysql']['username']
    @password = config['mysql']['password']
    @backup_dir = config['backup_dir'] || '.'
    @b2_enabled = config['b2_enabled'] || false
    @b2_key_id = config['b2']&.dig('key_id')
    @b2_application_key = config['b2']&.dig('application_key')
    @b2_bucket_name = config['b2']&.dig('bucket_name')
    @local_retention_days = config['local_retention_days'] || 30
    @b2_retention_days = config['b2']&.dig('retention_days') || 30
    @logger = logger
  end

  def backup # rubocop:disable Metrics/MethodLength
    @logger.info('Backing up MySQL database.')

    timestamp = Time.now.strftime('%Y-%m-%d_%H-%M-%S')
    @logger.info("Timestamp for backup: #{timestamp}")

    databases = find_databases

    databases.each do |database_name|
      backup_file = File.join(@backup_dir, "#{database_name}_#{timestamp}.sql")
      @logger.info("Backup file path: #{backup_file}")
      @logger.info("MySQL Info: #{@host} #{@username} #{@password} #{backup_file}")

      `mysqldump --host=#{@host} --user=#{@username} --password='#{@password}'
      --databases #{database_name} > #{backup_file}`

      delete_old_backups

      upload_to_b2(backup_file) if @b2_enabled
    end
  end

  def find_databases
    databases_output = `mysql --host=#{@host} --user=#{@username} --password='#{@password}' --execute='SHOW DATABASES;'`
    databases = databases_output.split("\n")[1..] # Ignore the first line (header)
    databases.reject { |db| %w[information_schema performance_schema mysql sys].include?(db) }
  end

  def delete_old_backups # rubocop:disable Metrics/MethodLength
    @logger.info('Deleting old backups.')

    max_age_days = @local_retention_days
    max_age_seconds = max_age_days * 24 * 60 * 60
    backups = Dir[File.join(@backup_dir, '*_*.sql')]

    return if backups.empty?

    backups.each do |backup|
      age_seconds = Time.now - File.mtime(backup)

      if age_seconds > max_age_seconds
        @logger.info("Deleted old backup: #{backup}")
        File.delete(backup)
      end
    end
  end

  def upload_to_b2(backup_file) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    b2_file_name = File.basename(backup_file)
    b2_file_url = "b2://#{@b2_bucket_name}/#{b2_file_name}"

    # Upload the backup file to the B2 bucket
    `b2 upload-file #{@b2_bucket_name} #{backup_file} #{b2_file_name}`
    @logger.info("Uploaded backup file to B2 bucket: #{b2_file_url}")

    # Calculate the cutoff date based on b2_retention_days
    max_age_days = @b2_retention_days
    cutoff_date = Time.now - (max_age_days * 24 * 60 * 60)

    existing_files = `b2 ls #{@b2_bucket_name}`

    return if existing_files.empty?

    existing_files.each_line do |line|
      file_name = line.split(' ').last.strip
      file_timestamp_str = file_name.match(/_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.sql/)&.captures&.first

      # Skip files that don't match the expected filename format
      next if file_timestamp_str.nil?

      file_timestamp = Time.strptime(file_timestamp_str, '%Y-%m-%d_%H-%M-%S')

      next unless file_timestamp < cutoff_date

      file_id = line.match(/"fileId": "([^"]+)"/)[1]
      `b2 delete-file-version #{@b2_bucket_name} #{file_name} #{file_id}`
      @logger.info("Deleted old backup file from B2 bucket: #{file_name}")
    end
  end
end
