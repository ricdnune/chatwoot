# Applies Terranet's branding values to the installation configs that Community Edition already reads
# (GlobalConfig -> installation_configs). It writes ONLY the whitelisted keys and is idempotent.
#
# Before the first managed write it snapshots the 7 whitelisted keys (present/absent + exact value) into a git-ignored file,
# so `restore_previous` returns an installation to what it really had, not to upstream's defaults.
# `reset_to_upstream_defaults` is the separate, explicit "back to config/installation_config.yml" operation.
# Run via `rails terranet:branding:apply|status|restore|reset_to_upstream_defaults` (DRY_RUN=1 to preview).
module Terranet::Branding
  KEYS = %w[INSTALLATION_NAME BRAND_NAME BRAND_URL WIDGET_BRAND_URL LOGO LOGO_DARK LOGO_THUMBNAIL].freeze
  TERRANET_FILE = Rails.root.join('config/terranet/branding.yml')
  UPSTREAM_FILE = Rails.root.join('config/installation_config.yml')
  DEFAULT_BACKUP_FILE = Rails.root.join('tmp/terranet/branding_backup.json')

  class NoBackupError < StandardError; end

  # Override with TERRANET_BRANDING_BACKUP to keep the snapshot on a persistent volume (tmp/ is ephemeral in containers).
  def self.backup_file
    Pathname.new(ENV.fetch('TERRANET_BRANDING_BACKUP', DEFAULT_BACKUP_FILE.to_s))
  end

  def self.terranet_values
    YAML.safe_load_file(TERRANET_FILE).tap { |values| ensure_whitelisted!(values.keys, 'branding.yml') }
  end

  def self.upstream_values
    YAML.safe_load_file(UPSTREAM_FILE).to_h { |config| [config['name'], config['value']] }.slice(*KEYS)
  end

  # Returns { key => [old, new] } for the keys that differ; writes them unless dry_run.
  # All-or-nothing: a failure rolls back every key and removes a snapshot created by this very run.
  def self.apply(values: terranet_values, dry_run: false)
    ensure_whitelisted!(values.keys, 'values')
    snapshot_created = false
    InstallationConfig.transaction do
      rows = lock_rows
      changes = pending_changes(rows, values)
      unless dry_run || changes.empty?
        snapshot_created = write_backup(rows)
        changes.each { |key, (_old, new_value)| write_value(rows[key], key, new_value) }
      end
      changes
    end
  rescue StandardError
    backup_file.delete if snapshot_created && backup_file.exist?
    raise
  end

  def self.reset_to_upstream_defaults(dry_run: false)
    apply(values: upstream_values, dry_run: dry_run)
  end

  # Returns { key => [current, restored] } (restored nil = the key did not exist and is removed).
  def self.restore_previous(dry_run: false)
    snapshot = read_backup
    changes = InstallationConfig.transaction do
      rows = lock_rows
      diff = restore_diff(rows, snapshot)
      diff.each_key { |key| restore_key(rows[key], key, snapshot[key]) } unless dry_run
      diff
    end
    archive_backup unless dry_run
    changes
  end

  def self.status
    desired = terranet_values
    desired.to_h { |key, value| [key, { current: InstallationConfig.find_by(name: key)&.value, desired: value }] }
  end

  def self.ensure_whitelisted!(keys, source)
    unknown = keys - KEYS
    raise ArgumentError, "#{source} has keys outside the whitelist: #{unknown.join(', ')}" if unknown.any?
  end

  def self.pending_changes(rows, values)
    values.reject { |key, new_value| rows.key?(key) && rows[key].value == new_value }.to_h { |key, new_value| [key, [rows[key]&.value, new_value]] }
  end

  def self.write_value(row, key, value)
    (row || InstallationConfig.new(name: key)).tap { |config| config.value = value }.save!
  end

  def self.restore_diff(rows, snapshot)
    KEYS.each_with_object({}) do |key, diff|
      entry = snapshot[key]
      next if entry['present'] ? rows[key]&.value == entry['value'] && rows.key?(key) : !rows.key?(key)

      diff[key] = [rows[key]&.value, entry['value']]
    end
  end

  def self.restore_key(row, key, entry)
    entry['present'] ? write_value(row, key, entry['value']) : row.destroy!
  end

  def self.lock_rows
    InstallationConfig.where(name: KEYS).lock.index_by(&:name)
  end

  # Keeps the ORIGINAL state: an existing snapshot is never overwritten. Returns true when it created one.
  def self.write_backup(rows)
    return false if backup_file.exist?

    snapshot = KEYS.index_with { |key| rows[key] ? { 'present' => true, 'value' => rows[key].value } : { 'present' => false } }
    backup_file.dirname.mkpath
    File.chmod(0o700, backup_file.dirname)
    temp = backup_file.sub_ext(".#{Process.pid}.tmp")
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate('keys' => snapshot)) }
    File.rename(temp, backup_file)
    true
  end

  def self.read_backup
    raise NoBackupError, "no branding backup at #{backup_file}; use reset_to_upstream_defaults for upstream values" unless backup_file.exist?

    keys = JSON.parse(backup_file.read).fetch('keys')
    ensure_whitelisted!(keys.keys, 'backup')
    raise ArgumentError, 'backup is missing keys' unless keys.keys.sort == KEYS.sort
    raise ArgumentError, 'backup has malformed entries' unless keys.values.all? { |entry| valid_entry?(entry) }

    keys
  end

  def self.valid_entry?(entry)
    entry.is_a?(Hash) && [true, false].include?(entry['present']) && (!entry['present'] || entry['value'].nil? || entry['value'].is_a?(String))
  end

  def self.archive_backup
    File.rename(backup_file, backup_file.sub_ext(".restored-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json"))
  end
end
