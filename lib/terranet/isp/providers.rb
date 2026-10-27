# Read-only provider clients. Each returns Terranet::Isp::SecureHttp::Result for a connection check and normalizes
# provider payloads through a strict whitelist: anything not listed (passwords, PPPoE/WiFi credentials, raw JSON) is dropped.
module Terranet::Isp::Providers
  # Normalized, read-only views. Only these fields ever leave the adapter.
  Service = Struct.new(:service_id, :status, :plan, :zone, :onu_serial, keyword_init: true)
  Onu = Struct.new(:external_id, :serial, :status, :olt_id, :zone, keyword_init: true)

  def self.for(credential)
    case credential.provider
    when 'wisphub' then Wisphub.new(credential)
    when 'smartolt' then Smartolt.new(credential)
    else raise Terranet::Isp::Error, 'unknown provider'
    end
  end
end
