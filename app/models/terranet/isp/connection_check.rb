class Terranet::Isp::ConnectionCheck < ApplicationRecord
  RETENTION = 200 # per credential

  validates :account_id, :credential_id, :mode, presence: true

  def readonly?
    persisted? || super
  end

  scope :recent, -> { order(created_at: :desc, id: :desc) }
end
