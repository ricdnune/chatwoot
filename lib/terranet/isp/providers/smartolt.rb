# SmartOLT API: `X-Token`, base https://<subdomain>.smartolt.com/api. The connection check lists OLTs (read-only, cheap).
# Detail payloads carry username/password for the ONU: they are not part of the whitelist and are dropped.
class Terranet::Isp::Providers::Smartolt < Terranet::Isp::Providers::Base
  ONU_FIELDS = { 'unique_external_id' => :external_id, 'sn' => :serial, 'status' => :status, 'olt_id' => :olt_id, 'zone_name' => :zone }.freeze

  def self.normalize_onu(raw)
    Terranet::Isp::Providers::Onu.new(**ONU_FIELDS.to_h do |source, target|
      [target, raw[source].is_a?(String) || raw[source].is_a?(Numeric) ? raw[source].to_s : nil]
    end)
  end

  private

  def connection_check_path = '/system/get_olts'
  def auth_headers = { 'X-Token' => secret }
end
