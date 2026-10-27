# Everything under Terranet ISP is for a real Super Admin only (authenticate_super_admin! comes from the parent) and is always
# scoped to the account in the URL; no role, account or URL is ever taken from a request body.
class Terranet::Isp::Admin::BaseController < SuperAdmin::ApplicationController
  before_action :set_account
  helper_method :isp_accounts

  private

  # Administrate derives the namespace (sidebar, resource lookup) from the controller path; this one lives outside super_admin/.
  def namespace
    :super_admin
  end

  def set_account
    @account = Account.find(params[:account_id])
  end

  def isp_accounts
    @isp_accounts ||= Account.order(:id).select(:id, :name)
  end

  def audit!(action, outcome, subject: nil, metadata: {})
    Terranet::Isp::AuditEvent.record!(account: @account, actor: current_super_admin, action: action, outcome: outcome, subject: subject,
                                      request_id: request.request_id, metadata: metadata)
  end
end
