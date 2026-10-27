class Terranet::Isp::Admin::AuditEventsController < Terranet::Isp::Admin::BaseController
  PAGE_SIZE = 100

  def index
    @events = Terranet::Isp::AuditEvent.where(account_id: @account.id).recent.limit(PAGE_SIZE)
    @actors = User.where(id: @events.filter_map(&:actor_id)).pluck(:id, :name).to_h
  end
end
