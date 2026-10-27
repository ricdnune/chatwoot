class Terranet::Isp::Admin::OverviewController < Terranet::Isp::Admin::BaseController
  skip_before_action :set_account, only: :index

  def index
    account = Account.find_by(id: params[:account_id]) || Account.order(:id).first
    return render :no_accounts if account.nil?

    redirect_to super_admin_terranet_isp_overview_path(account_id: account.id)
  end

  def show
    @credentials = Terranet::Isp::ProviderCredential.for_account(@account).index_by(&:provider)
    @candidates_pending = Terranet::Isp::Binding.for_account(@account).where(status: 'candidate').count
  end
end
