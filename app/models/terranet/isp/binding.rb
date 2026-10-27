# Candidate link between a Chatwoot contact and a provider service/ONU. Nothing here is auto-confirmed: a human decides, and
# every decision is audited (ADR 08). A phone number never determines identity.
class Terranet::Isp::Binding < ApplicationRecord
  STATUSES = %w[candidate confirmed rejected revoked].freeze
  MATCHED_BY = %w[sn_onu manual].freeze
  REASONS = %w[verified_with_subscriber verified_by_document data_mismatch duplicate_service other].freeze
  # target status => statuses it may be reached from
  TRANSITIONS = { 'confirmed' => %w[candidate], 'rejected' => %w[candidate], 'revoked' => %w[confirmed] }.freeze

  validates :account_id, :contact_id, :wisphub_service_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :matched_by, inclusion: { in: MATCHED_BY }
  validates :decision_reason, inclusion: { in: REASONS }, allow_nil: true

  scope :for_account, ->(account) { where(account_id: account.id) }
  scope :ordered, -> { order(:id) }

  def contact
    Contact.find_by(id: contact_id, account_id: account_id)
  end

  def decide!(status:, reason:, actor:)
    raise ArgumentError, 'a decision needs a reason' if reason.blank?
    raise ArgumentError, "cannot move from #{self.status} to #{status}" unless TRANSITIONS.fetch(status, []).include?(self.status)

    update!(status: status, decision_reason: reason, decided_by_id: actor.id, decided_at: Time.current)
  end
end
