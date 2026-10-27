# Terranet ISP module: provider credentials (WispHub, SmartOLT), connection checks, audit trail and identity candidates.
# Everything lives under this namespace; upstream is touched only by the route/menu hooks in config/initializers/terranet_isp.rb.
module Terranet::Isp
  VERSION = 'm4.1-lab'.freeze
  PROVIDERS = %w[wisphub smartolt].freeze

  class Error < StandardError; end
  # Raised instead of silently storing or reading a credential in clear text.
  class EncryptionNotConfigured < Error; end

  def self.table_name_prefix
    'terranet_isp_'
  end

  # :mock (default) talks only to the local mock server. :live is not approved yet and is reachable only by an explicit env flag.
  def self.mode
    ENV['TERRANET_ISP_MODE'] == 'live' ? :live : :mock
  end

  def self.encryption_configured?
    Chatwoot.encryption_configured?
  end
end
