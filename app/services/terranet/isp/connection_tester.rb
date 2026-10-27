# Runs one read-only connection check for a credential, records it and audits it. Talks to the local mock unless the module is
# explicitly switched to live (not approved). Never logs or stores the response body or the credential.
class Terranet::Isp::ConnectionTester
  Outcome = Struct.new(:ok, :error_code, :latency_ms, keyword_init: true)

  def initialize(credential:, actor:, request_id: nil)
    @credential = credential
    @actor = actor
    @request_id = request_id
  end

  def call
    result = perform
    record(result)
    Outcome.new(ok: result.ok?, error_code: result.error_code, latency_ms: result.latency_ms)
  end

  private

  def perform
    return failure('encryption_not_configured') unless Terranet::Isp.encryption_configured?
    return failure('no_secret') unless @credential.secret_configured?
    return failure('rate_limited_locally') if @credential.rate_limited?

    Terranet::Isp::Providers.for(@credential).check_connection
  rescue Terranet::Isp::Error => e
    Rails.logger.warn("[terranet_isp] check refused provider=#{@credential.provider} error=#{e.class.name.demodulize}")
    failure('check_refused')
  end

  def failure(code)
    Terranet::Isp::SecureHttp::Result.new(error_code: code, latency_ms: 0)
  end

  def record(result)
    Terranet::Isp::ProviderCredential.transaction do
      update_credential(result)
      Terranet::Isp::ConnectionCheck.create!(account_id: @credential.account_id, credential_id: @credential.id, actor_id: @actor.id, ok: result.ok?,
                                             http_status: result.status, latency_ms: result.latency_ms, error_code: result.error_code,
                                             mode: Terranet::Isp.mode.to_s, created_at: Time.current)
      prune_history
      audit(result)
    end
  end

  def update_credential(result)
    @credential.update!(status: result.ok? ? 'connected' : 'error', last_checked_at: Time.current, last_latency_ms: result.latency_ms,
                        last_error_code: result.error_code,
                        rate_limited_until: result.retry_after ? result.retry_after.seconds.from_now : @credential.rate_limited_until)
  end

  def prune_history
    stale = Terranet::Isp::ConnectionCheck.where(credential_id: @credential.id).recent.offset(Terranet::Isp::ConnectionCheck::RETENTION).pluck(:id)
    Terranet::Isp::ConnectionCheck.where(id: stale).delete_all if stale.any?
  end

  def audit(result)
    account = Account.find(@credential.account_id)
    Terranet::Isp::AuditEvent.record!(
      account: account, actor: @actor, action: 'provider.connection_tested', outcome: result.ok? ? 'success' : 'failure', subject: @credential,
      request_id: @request_id,
      metadata: { provider: @credential.provider, environment: @credential.environment, mode: Terranet::Isp.mode.to_s,
                  error_code: result.error_code, http_status: result.status, latency_ms: result.latency_ms }.compact
    )
  end
end
