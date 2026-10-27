# Builds the only URL a provider client may call. The browser never supplies a URL: hosts come from fixed values (WispHub),
# a strictly validated subdomain (SmartOLT) or, in mock mode, an operator-set env var restricted to local names.
require 'resolv'
require 'ipaddr'

class Terranet::Isp::Endpoint
  WISPHUB_HOSTS = { 'sandbox' => 'sandbox-api.wisphub.net', 'production' => 'api.wisphub.net' }.freeze
  SMARTOLT_SUBDOMAIN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  MOCK_HOSTS = /\A(?:isp-mock|localhost|127\.0\.0\.1|[a-z0-9-]+\.test)\z/
  DEFAULT_MOCK_URL = 'http://isp-mock:4010'.freeze
  # SSRF blocklist: private ranges are named on purpose, hence the markers for terranet/tools/disclosure_scan.sh
  PRIVATE_RANGES = [
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', # disclosure:ignore
    '172.16.0.0/12', '192.0.0.0/24', '192.168.0.0/16', '198.18.0.0/15', # disclosure:ignore
    '224.0.0.0/4', '240.0.0.0/4', '::1/128', 'fc00::/7', 'fe80::/10', '::ffff:0:0/96'
  ].map { |range| IPAddr.new(range) }.freeze

  class Invalid < Terranet::Isp::Error; end

  attr_reader :scheme, :host, :port, :base_path

  def self.for(provider:, environment:, subdomain: nil)
    Terranet::Isp.mode == :live ? live(provider, environment, subdomain) : mock(provider)
  end

  def self.valid_subdomain?(value)
    value.is_a?(String) && value.match?(SMARTOLT_SUBDOMAIN)
  end

  def self.live(provider, environment, subdomain)
    case provider
    when 'wisphub' then new('https', WISPHUB_HOSTS.fetch(environment) { raise Invalid, 'unknown WispHub environment' }, 443, '/api')
    when 'smartolt'
      raise Invalid, 'invalid SmartOLT subdomain' unless valid_subdomain?(subdomain)

      new('https', "#{subdomain}.smartolt.com", 443, '/api')
    else raise Invalid, 'unknown provider'
    end
  end

  def self.mock(provider)
    raise Invalid, 'unknown provider' unless Terranet::Isp::PROVIDERS.include?(provider)

    uri = URI.parse(ENV.fetch('TERRANET_ISP_MOCK_URL', DEFAULT_MOCK_URL))
    raise Invalid, 'mock URL must be a bare local http origin' unless uri.userinfo.nil? && uri.path.in?(['', '/']) && uri.host.to_s.match?(MOCK_HOSTS)

    new(uri.scheme, uri.host, uri.port, "/#{provider}/api")
  end

  def initialize(scheme, host, port, base_path)
    @scheme = scheme
    @host = host
    @port = port
    @base_path = base_path
  end

  def mock?
    Terranet::Isp.mode == :mock
  end

  # Live hosts must not resolve to loopback/private/link-local space (DNS rebinding / SSRF); returns the pinned IP to connect to.
  def pinned_ip
    return nil if mock?

    addresses = Resolv.getaddresses(host)
    raise Invalid, 'host does not resolve' if addresses.empty?
    raise Invalid, 'host resolves to a non-public address' if addresses.any? do |address|
      PRIVATE_RANGES.any? do |range|
        range.include?(IPAddr.new(address))
      end
    end

    addresses.first
  end
end
