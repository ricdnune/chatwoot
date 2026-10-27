# Append-only. Metadata is restricted to a whitelist of non-sensitive keys: no secrets, no HTTP bodies, no PII.
class Terranet::Isp::AuditEvent < ApplicationRecord
  ACTIONS = %w[provider.settings_updated provider.secret_set provider.secret_rotated provider.connection_tested
               binding.confirmed binding.rejected binding.revoked].freeze
  OUTCOMES = %w[success failure denied].freeze
  METADATA_KEYS = %w[provider environment error_code http_status latency_ms mode reason binding_status].freeze

  validates :account_id, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :outcome, inclusion: { in: OUTCOMES }
  validate :metadata_is_whitelisted

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # rubocop:disable Metrics/ParameterLists
  def self.record!(account:, actor:, action:, outcome:, subject: nil, request_id: nil, metadata: {})
    create!(account_id: account.id, actor_id: actor&.id, action: action, outcome: outcome, subject_type: subject&.class&.name,
            subject_id: subject&.id, request_id: request_id, metadata: metadata.stringify_keys)
  end
  # rubocop:enable Metrics/ParameterLists

  def readonly?
    persisted? || super
  end

  before_destroy { raise ActiveRecord::ReadOnlyRecord, 'audit events are append-only' }

  private

  def metadata_is_whitelisted
    unknown = metadata.keys - METADATA_KEYS
    errors.add(:metadata, "has keys outside the whitelist: #{unknown.join(', ')}") if unknown.any?
  end
end
