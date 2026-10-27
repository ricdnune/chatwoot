# Applies Terranet's branding values to the installation configs that Community Edition already reads
# (GlobalConfig -> installation_configs). It writes ONLY the whitelisted keys, never creates others, is idempotent,
# and can restore upstream's defaults. Run via `rails terranet:branding:apply|status|revert` (DRY_RUN=1 to preview).
module Terranet::Branding
  KEYS = %w[INSTALLATION_NAME BRAND_NAME BRAND_URL WIDGET_BRAND_URL LOGO LOGO_DARK LOGO_THUMBNAIL].freeze
  TERRANET_FILE = Rails.root.join('config/terranet/branding.yml')
  UPSTREAM_FILE = Rails.root.join('config/installation_config.yml')

  def self.terranet_values
    YAML.safe_load_file(TERRANET_FILE).tap do |values|
      unknown = values.keys - KEYS
      raise ArgumentError, "branding.yml has keys outside the whitelist: #{unknown.join(', ')}" if unknown.any?
    end
  end

  def self.upstream_values
    YAML.safe_load_file(UPSTREAM_FILE).to_h { |config| [config['name'], config['value']] }.slice(*KEYS)
  end

  # Returns { key => [old, new] } for the keys that differ; writes them unless dry_run.
  def self.apply(values: terranet_values, dry_run: false)
    values.each_with_object({}) do |(key, new_value), changes|
      config = InstallationConfig.find_or_initialize_by(name: key)
      next if config.persisted? && config.value == new_value

      changes[key] = [config.value, new_value]
      next if dry_run

      config.value = new_value
      config.save!
    end
  end

  def self.revert(dry_run: false)
    apply(values: upstream_values, dry_run: dry_run)
  end

  def self.status
    desired = terranet_values
    desired.to_h { |key, value| [key, { current: InstallationConfig.find_by(name: key)&.value, desired: value }] }
  end
end
