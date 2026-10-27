# WispHub API (https://wisphub.net/api-docs/): `Authorization: Api-Key <key>`. The connection check lists one client.
# UNVERIFIED against the real sandbox: this path/behaviour comes from the public OpenAPI, not from a live call.
class Terranet::Isp::Providers::Wisphub < Terranet::Isp::Providers::Base
  SERVICE_FIELDS = { 'id_servicio' => :service_id, 'estado' => :status, 'plan_internet' => :plan, 'zona' => :zone, 'sn_onu' => :onu_serial }.freeze

  def self.normalize_service(raw)
    Terranet::Isp::Providers::Service.new(**SERVICE_FIELDS.to_h { |source, target| [target, scalar(raw[source])] })
  end

  # plan_internet/zona arrive as nested objects in some payloads; keep only a printable name.
  def self.scalar(value)
    value = value['nombre'] if value.is_a?(Hash)
    value.is_a?(String) || value.is_a?(Numeric) ? value.to_s.truncate(120) : nil
  end

  private

  def connection_check_path = '/clientes/'
  def connection_check_query = { limit: 1 }
  def auth_headers = { 'Authorization' => "Api-Key #{secret}" }
end
