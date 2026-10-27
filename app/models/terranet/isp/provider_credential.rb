# One credential per account and provider. The secret is Active Record Encrypted (non-deterministic) and the model fails closed:
# without ACTIVE_RECORD_ENCRYPTION_* keys nothing is stored, and a clear-text value found in the column is never accepted.
class Terranet::Isp::ProviderCredential < ApplicationRecord
  ENVIRONMENTS = %w[sandbox production].freeze
  STATUSES = %w[not_configured configured connected error].freeze
  SECRET_FORMAT = /\A[\x21-\x7E]{8,512}\z/ # printable ASCII, no spaces/newlines (header injection), bounded length

  encrypts :secret

  validates :account_id, presence: true
  validates :provider, inclusion: { in: Terranet::Isp::PROVIDERS }, uniqueness: { scope: :account_id }
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :status, inclusion: { in: STATUSES }
  validates :subdomain, format: { with: Terranet::Isp::Endpoint::SMARTOLT_SUBDOMAIN }, if: -> { provider == 'smartolt' }
  validates :subdomain, absence: true, if: -> { provider == 'wisphub' }
  validates :environment, inclusion: { in: %w[production] }, if: -> { provider == 'smartolt' }

  before_validation :reset_secret_on_environment_change, on: :update
  before_save :ensure_encryption_configured, if: :will_save_change_to_secret?

  scope :for_account, ->(account) { where(account_id: account.id) }

  def self.fetch_for(account, provider)
    for_account(account).find_or_initialize_by(provider: provider) do |credential|
      credential.environment = provider == 'smartolt' ? 'production' : 'sandbox'
    end
  end

  def secret_configured?
    secret_before_type_cast.present?
  end

  # Replaces (or sets) the secret. Rotation requires a new value; the previous one is never read back.
  def replace_secret!(value, actor:)
    raise ArgumentError, 'secret does not match the allowed format' unless value.is_a?(String) && value.match?(SECRET_FORMAT)

    self.secret = value
    self.status = 'configured'
    self.last_error_code = nil
    self.rotated_at = Time.current
    self.rotated_by_id = actor.id
    save!
  end

  # Used only by the provider clients. Refuses unless the stored value is really ciphertext.
  def secret_value
    raise Terranet::Isp::EncryptionNotConfigured, 'ACTIVE_RECORD_ENCRYPTION_* keys are not configured' unless Terranet::Isp.encryption_configured?
    raise Terranet::Isp::Error, 'no secret configured' unless secret_configured?
    raise Terranet::Isp::Error, 'stored secret is not encrypted' unless ActiveRecord::Encryption.encryptor.encrypted?(secret_before_type_cast)

    secret
  end

  def rate_limited?
    rate_limited_until.present? && rate_limited_until.future?
  end

  def serializable_hash(options = nil)
    super((options || {}).merge(except: Array(options&.dig(:except)) + %w[secret]))
  end

  private

  def ensure_encryption_configured
    raise Terranet::Isp::EncryptionNotConfigured, 'ACTIVE_RECORD_ENCRYPTION_* keys are not configured' unless Terranet::Isp.encryption_configured?
  end

  # WispHub issues different keys for sandbox and production: switching environment drops the old secret.
  def reset_secret_on_environment_change
    return unless environment_changed?

    self.secret = nil
    self.status = 'not_configured'
    self.last_checked_at = self.last_latency_ms = self.last_error_code = self.rate_limited_until = nil
  end
end
