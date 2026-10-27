class Terranet::Isp::Providers::Base
  def initialize(credential)
    @credential = credential
  end

  def check_connection
    client.get(connection_check_path, headers: auth_headers, query: connection_check_query)
  end

  private

  def client
    @client ||= Terranet::Isp::SecureHttp.new(
      Terranet::Isp::Endpoint.for(provider: @credential.provider, environment: @credential.environment, subdomain: @credential.subdomain)
    )
  end

  # The decrypted secret exists only inside this call frame, as a header value.
  def secret
    @credential.secret_value
  end

  def connection_check_query
    {}
  end
end
