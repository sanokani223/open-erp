# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :refresh_token, :default_initial_date, :default_final_date, :date_range, :bling_order_items,
                :current_done_order_items, :set_monthly_revenue_estimation,
                :get_in_progress_order_items, :get_printed_order_items,
                :get_pending_order_items, :canceled_orders, :collected_orders, only: :index
  include SheinOrdersHelper

  def index
    authorize BlingOrderItem
    @expires_at = format_last_update(@date_expires)

    @last_update = format_last_update(Time.current)

    @grouped_printed_order_items = BlingOrderItem.group_order_items(@printed_order_items)
    @grouped_pending_order_items = BlingOrderItem.group_order_items(@pending_order_items)
    @grouped_in_progress_order_items = BlingOrderItem.group_order_items(@in_progress_order_items)
  end

  def last_updates
    @custumers = Customer.order(id: :desc).limit(10)
    @products = Product.order(id: :desc).limit(10)
  end

  private

  def default_initial_date
    @default_initial_date = params[:initial_date] || Time.zone.today
  end

  def default_final_date
    @default_final_date = params[:final_date] || Time.zone.today
  end

  def date_range
    @first_date = params.try(:fetch, :bling_order_item, nil).try(:fetch, :initial_date, nil).try(:to_date).try(:beginning_of_day) || Time.zone.today.beginning_of_day
    @second_date = params.try(:fetch, :bling_order_item, nil).try(:fetch, :final_date, nil).try(:to_date).try(:end_of_day) || Time.zone.today.end_of_day
    @date_range = @first_date.to_date.beginning_of_day..@second_date.end_of_day
  end

  def bling_order_items
    base_query = BlingOrderItem.where(situation_id: BlingOrderItem::Status::WITHOUT_CANCELLED,
                                      account_id: current_user.account.id)
                               .date_range(@default_initial_date, @default_final_date)

    @bling_order_items = BlingOrderItem.group_order_items(base_query)
  end

  def get_in_progress_order_items
    @in_progress_order_items = BlingOrderItem.where(situation_id: BlingOrderItem::Status::IN_PROGRESS,
                                                    account_id: current_user.account.id)
  end

  def collected_orders
    base_query = BlingOrderItem.where(situation_id: BlingOrderItem::Status::COLLECTED,
                                      account_id: current_user.account.id,
                                      collected_alteration_date: @default_initial_date..@default_final_date)
    @collected_orders = BlingOrderItem.group_order_items(base_query)
  end

  def finance_per_status
    @pendings = SheinOrder.where("data ->> 'Status do pedido' = ?", 'Pendente')
    @to_be_colected = SheinOrder.where("data ->> 'Status do pedido' = ?", 'Para ser coletado por SHEIN')
    @to_be_sent = SheinOrder.where("data ->> 'Status do pedido' = ?", 'Para ser enviado por SHEIN')
    @sent = SheinOrder.where("data ->> 'Status do pedido' = ?", 'Enviado')
  end

  def current_done_order_items
    base_query = BlingOrderItem.where(situation_id: [BlingOrderItem::Status::VERIFIED,
                                                     BlingOrderItem::Status::CHECKED,
                                                     BlingOrderItem::Status::COLLECTED],
                                      alteration_date: @default_initial_date.to_date.beginning_of_day..@default_final_date.to_date.end_of_day,
                                      account_id: current_user.account.id)
    @current_done_order_items = BlingOrderItem.group_order_items(base_query)
  end

  def get_printed_order_items
    @printed_order_items = BlingOrderItem.where(situation_id: BlingOrderItem::Status::PRINTED,
                                                account_id: current_user.account.id)
  end

  def get_pending_order_items
    @pending_order_items = BlingOrderItem.where(situation_id: BlingOrderItem::Status::PENDING,
                                                account_id: current_user.account.id)
  end

  def canceled_orders
    base_query = BlingOrderItem.where(situation_id: BlingOrderItem::Status::CANCELED,
                                      account_id: current_user.account.id)
                               .date_range(@default_initial_date, @default_final_date)

    @canceled_orders = BlingOrderItem.group_order_items(base_query)
  end

  def set_monthly_revenue_estimation
    @monthly_revenue_estimation = RevenueEstimation.current_month.take
  end

  def count_mercado_envios_flex(order_ids)
    # TODO, get it from the database directly.
    return if order_ids.blank?

    counter = 0
    order_ids.each do |order_id|
      response = Services::Bling::FindOrder.call(id: order_id, order_command: 'find_order',
                                                 tenant: current_user.account.id)
      order = response['data']

      shipping = order['transporte']
      shipping_service = shipping['volumes'][0]['servico']
      counter += 1 if shipping_service == 'Mercado Envios Flex'
    rescue StandardError => e
      Rails.logger.error('Not Mercado Envios Flex')
      Rails.logger.error(e.message)
    end
    counter
  end

  def fetch_order_data(order_id)
    Services::Bling::FindOrder.call(id: order_id, order_command: 'find_order',
                                    tenant: current_user.account.id)
  end

  def format_last_update(time)
    time&.strftime('%d-%m-%Y %H:%M:%S')
  end

  def token_expires_at
    BlingDatum.find_by(account_id: current_tenant.id).try(:expires_at)
  end

  def refresh_token
    @date_expires = token_expires_at
    return if @date_expires.blank? || (@date_expires > DateTime.now && !Rails.env.eql?('production'))

    refresh_token = BlingDatum.find_by(account_id: current_tenant.id).refresh_token
    client_id = ENV['CLIENT_ID']
    client_secret = ENV['CLIENT_SECRET']
    credentials = Base64.strict_encode64("#{client_id}:#{client_secret}")
    @expires_at = format_last_update(@date_expires)
    @last_update = format_last_update(Time.current)
    begin
      @response = HTTParty.post('https://bling.com.br/Api/v3/oauth/token',
                                body: {
                                  grant_type: 'refresh_token',
                                  refresh_token:
                                },
                                headers: {
                                  'Content-Type' => 'application/x-www-form-urlencoded',
                                  'Accept' => '1.0',
                                  'Authorization' => "Basic #{credentials}"
                                })

      verify_tokens
    rescue StandardError => e
      Rails.logger.error(e.message)
    end
  end

  def verify_tokens
    tokens = BlingDatum.find_by(account_id: current_tenant.id)
    tokens.update(access_token: @response['access_token'],
                  expires_in: @response['expires_in'],
                  expires_at: Time.zone.now + @response['expires_in'].seconds,
                  token_type: @response['token_type'],
                  scope: @response['scope'])
  end

  def get_loja_name
    {
      204_219_105 => 'Shein',
      203_737_982 => 'Shopee',
      203_467_890 => 'Simplo 7',
      204_061_683 => 'Mercado Livre'
    }
  end
end
