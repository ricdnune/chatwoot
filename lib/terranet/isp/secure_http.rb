# Minimal read-only HTTP client for provider APIs: GET only, no redirects, bounded time and size, JSON only.
# Returns a Result carrying a stable error_code; never the response body, the headers or the credential.
require 'net/http'

class Terranet::Isp::SecureHttp
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 8
  MAX_BYTES = 256.kilobytes
  DEFAULT_RETRY_AFTER = 60
  MAX_RETRY_AFTER = 1.hour.to_i
  ERROR_CODES = { 401 => 'unauthorized', 403 => 'forbidden', 404 => 'not_found', 429 => 'rate_limited' }.freeze

  Result = Struct.new(:status, :json, :latency_ms, :error_code, :retry_after, keyword_init: true) do
    def ok? = error_code.nil?
  end

  class TooLarge < StandardError; end

  def initialize(endpoint)
    @endpoint = endpoint
  end

  def get(path, headers:, query: {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = perform(path, headers, query)
    build_result(response, started)
  rescue Timeout::Error # Net::OpenTimeout and Net::ReadTimeout are subclasses
    failure('timeout', started)
  rescue TooLarge
    failure('response_too_large', started)
  rescue Terranet::Isp::Endpoint::Invalid
    failure('endpoint_rejected', started)
  rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError
    failure('connection_failed', started)
  end

  private

  def perform(path, headers, query)
    builder = @endpoint.scheme == 'https' ? URI::HTTPS : URI::HTTP
    uri = builder.build(host: @endpoint.host, port: @endpoint.port, path: "#{@endpoint.base_path}#{path}", query: query.presence&.to_query)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.ipaddr = @endpoint.pinned_ip
    request = Net::HTTP::Get.new(uri, headers.merge('Accept' => 'application/json'))
    read_capped(http, request)
  end

  def read_capped(http, request)
    http.request(request) do |response|
      body = +''
      response.read_body do |chunk|
        body << chunk
        raise TooLarge if body.bytesize > MAX_BYTES
      end
      response.body = body
    end
  end

  def build_result(response, started)
    status = response.code.to_i
    return failure(ERROR_CODES.fetch(status, error_class(status)), started, status, retry_after_for(response)) unless response.is_a?(Net::HTTPSuccess)

    json = parse_json(response)
    return failure('invalid_response', started, status) if json.nil?

    Result.new(status: status, json: json, latency_ms: elapsed_ms(started))
  end

  # 3xx (redirect) is never followed: it could point to an internal host.
  def error_class(status)
    case status
    when 300..399 then 'redirect_blocked'
    when 500..599 then 'upstream_error'
    else 'http_error'
    end
  end

  def parse_json(response)
    return unless response['Content-Type'].to_s.start_with?('application/json')

    JSON.parse(response.body)
  rescue JSON::ParserError
    nil
  end

  def retry_after_for(response)
    return unless response.code.to_i == 429

    response['Retry-After'].to_s.match?(/\A\d+\z/) ? response['Retry-After'].to_i.clamp(1, MAX_RETRY_AFTER) : DEFAULT_RETRY_AFTER
  end

  def failure(code, started, status = nil, retry_after = nil)
    Result.new(status: status, latency_ms: elapsed_ms(started), error_code: code, retry_after: retry_after)
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
end
