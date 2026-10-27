# Local mock of the WispHub and SmartOLT read-only endpoints used by the connection check (Terranet ISP, M4.1 lab).
# ALL data is synthetic. The "credential" value selects the behaviour, so every failure mode can be exercised with fake tokens:
#   Any token STARTING with one of these prefixes (tokens must be 8+ chars, e.g. mock-ok-demo):
#   mock-ok       200 + JSON          mock-401 / mock-403 / mock-404      matching status
#   mock-429      429 + Retry-After   mock-redirect                       302 to an internal address
#   mock-slow     responds after 12 s (client timeout is 8 s)             mock-huge   oversize body
#   mock-html     200 with text/html  mock-leaky     200 JSON that includes password-like fields
require 'json'
require 'rack'

class IspMock
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  def call(env)
    request = Rack::Request.new(env)
    return [404, JSON_HEADERS, ['{"detail":"not found"}']] unless request.get?

    provider, token = credential_for(request)
    return [401, JSON_HEADERS, ['{"detail":"missing credentials"}']] if token.nil?

    behaviour(token, provider, request)
  end

  private

  def credential_for(request)
    case request.path_info
    when %r{\A/wisphub/api/clientes/?\z} then ['wisphub', request.get_header('HTTP_AUTHORIZATION').to_s.delete_prefix('Api-Key ').presence_or_nil]
    when %r{\A/smartolt/api/system/get_olts\z} then ['smartolt', request.get_header('HTTP_X_TOKEN').to_s.presence_or_nil]
    else [nil, nil]
    end
  end

  def behaviour(token, provider, _request)
    case token[/\Amock-(ok|401|403|404|429|redirect|slow|huge|html|leaky)/, 1]
    when '401', '403', '404' then [token[/\d+/].to_i, JSON_HEADERS, ['{"detail":"mock error"}']]
    when '429' then [429, JSON_HEADERS.merge('Retry-After' => '30'), ['{"response_code":"rate_limit_exceeded"}']]
    when 'redirect' then [302, { 'Location' => 'http://169.254.169.254/latest/meta-data/' }, []]
    when 'slow' then sleep(12) && [200, JSON_HEADERS, [payload(provider)]]
    when 'huge' then [200, JSON_HEADERS, ['{"pad":"' + ('x' * 400_000) + '"}']]
    when 'html' then [200, { 'Content-Type' => 'text/html' }, ['<html>not json</html>']]
    when 'ok', 'leaky' then [200, JSON_HEADERS, [payload(provider, leaky: token.start_with?('mock-leaky'))]]
    else [401, JSON_HEADERS, ['{"detail":"invalid credential"}']]
    end
  end

  def payload(provider, leaky: false)
    if provider == 'wisphub'
      row = { id_servicio: 900001, estado: 'Activo', plan_internet: { nombre: 'Plan Demo 20M' }, zona: { nombre: 'Zona Demo' }, sn_onu: 'DEMO00000001' }
      row.merge!(password_servicio: 'synthetic-secret', password_router_wifi: 'synthetic-wifi') if leaky
      JSON.generate(count: 1, next: nil, previous: nil, results: [row])
    else
      JSON.generate(status: true, response: [{ id: 1, name: 'OLT-DEMO-1', olt_hardware_version: 'DEMO' }])
    end
  end
end

class String
  def presence_or_nil = empty? ? nil : self
end

run IspMock.new
