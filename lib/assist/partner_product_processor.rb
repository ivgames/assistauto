module Assist
  class PartnerProductProcessor

    require 'json'
    require 'uri'

    class << self
      include Spree::Core::Engine.routes.url_helpers
      include Spree::PermittedAttributes
      include Spree::Core::ControllerHelpers::StrongParameters


      def add_single(params)

        @partner = Spree::Partner.find_by_id(params[:product][:partner_id])
        @brand = params[:product][:brand]
        @sku = params[:product][:sku]
        @response = get_product_data

        puts @response[0]
        if @response && @response.length > 0 && @response.any?

          params[:product][:price] = calculate_price(@response[0]['price'])
          params[:product][:cost_price] = @response[0]['price']
          params[:product][:partner_count] = @response[0]['availability']
          params[:product][:delivery_time] = @response[0]['deliveryPeriod']
          product = add_product_from_price_row(@response[0]['description'], clear(@response[0]['numberFix']), @response[0]['brand'], "-","-",params)
        end
        product
      end
    end


    def self.import(params)
      spreadsheet = open_spreadsheet(params[:file])
      (5..spreadsheet.last_row).each do |i|
        name = spreadsheet.cell(i, 'B').to_s #Наименование
        sku = spreadsheet.cell(i, 'C').to_s #Артикул
        brand = spreadsheet.cell(i, 'D').to_s #Изготовитель
        oem_number = spreadsheet.cell(i, 'E').to_s #Оригинальный номер
        applicability = spreadsheet.cell(i, 'F').to_s #Применяемость

        sku = clear(sku)
        oem_number = clear(oem_number)

        add_product_from_price_row(name, sku, brand, oem_number, applicability, params)
      end

    end

    def self.get_product_analog(product)
      @product = product
      @partner = Spree::Partner.find_by_id(product.partner_id)
      @brand = @product.brand
      @sku = @product.sku
      response = HTTParty.get(search_articles_url)
    end

    # Get data from partner and update product fields
    def self.get_product_update(product)
      if (product.price === 0 || Time.now >= product.updated_at + 1.day) && !product.partner_id.nil?
        @product = product
        @partner = Spree::Partner.find_by_id(product.partner_id)
        @brand = @product.brand
        @sku = @product.sku
        @response = get_product_data

        puts @response.length
        if (@response && @response.length > 0 && @response.any?)
          update_product(@response)
        end
      end
    end

    def self.add_product_from_price_row(name, sku, brand, oem, applicability, params)
      # params[:product] = {}
      params[:product][:available_on] ||= Time.now
      params[:product][:name] = name
      params[:product][:description] = name
      params[:product][:meta_description] = name
      params[:product][:meta_keywords] = name
      params[:product][:sku] = sku
      params[:product][:brand] = brand
      params[:product][:oem_number] = oem
      params[:product][:applicability] = applicability
      params[:product][:shipping_category_id] = Spree::ShippingCategory.first.id

      params[:product][:product_properties_attributes] = []
      params[:product][:product_properties_attributes] << {:property_name => I18n.t('global.brand'),          :value=>brand,:position=>1}
      params[:product][:product_properties_attributes] << {:property_name => I18n.t('global.originalNumber'), :value=>oem,:position=>2}
      params[:product][:product_properties_attributes] << {:property_name => I18n.t('global.applicability'), :value=>applicability,:position=>3}


      @product = Spree::Core::Importer::Product.new(nil, product_params(params), {}).create
    end



    private

    def self.open_spreadsheet(file)
      case File.extname(file.original_filename)
        when ".csv" then Roo::Csv.new(file.path, nil, :ignore)
        when ".xls" then Roo::Excel.new(file.path, {})
        when ".xlsx" then Roo::Excelx.new(file.path, {})
        else raise "Unknown file type: #{file.original_filename}"
      end
    end

    def self.calculate_price(price)
      calculated_price = @partner.nil? ? price : (price + (price * (@partner.percents/100))).ceil
    end

    def self.update_product(response)
      puts response

      params = {}

      params[:available_on] ||= Time.now
      params[:name] = response[0]['description']
      params[:description] = response[0]['description']
      params[:meta_description] = response[0]['description']
      params[:meta_keywords] = response[0]['description']
      params[:price] = calculate_price(response[0]['price'])
      params[:cost_price] = response[0]['price'].ceil
      params[:sku] = response[0]['numberFix']
      params[:weight] = response[0]['weight']
      params[:partner_count] = response[0]['availability']
      params[:delivery_time] = response[0]['deliveryPeriod']

      @product.update_attributes(params)
    end

    def self.get_product_data
      response = HTTParty.get(search_articles_url)

      if response.success?

      else
        puts "Не удалось получить данные по товару:"+@sku.to_s+" бренда: "+@brand.to_s+" Попробуйте еще!"
      end

      @json = JSON.parse(response.body)
      # из ответа ищем конкретно по артикулу и марке
      filter_all = @json.select{|hash| hash['numberFix'] == clear(@sku) && hash['brand'].downcase.delete(' ') == @brand.downcase.delete(' ')}

      # Дальше нам нужен склад южного бутово, пытаемся фильтровать и отсеять именно этот склад
      filter_partner_stock = filter_all.select{|hash| hash['distributorId'] == @partner.stock}

      # на всякий случай сразу смотрим как и сос складом бутово, центральный склад
      filter_main_stock = filter_all.select{|hash| hash['distributorId'] == @partner.main_stock}

      # делаем окончательную выборку и того что отфильтровали
      filtered_stock = filter_partner_stock.length>0 ? filter_partner_stock : filter_main_stock.length > 0 ? filter_main_stock : find_with_minimum_delivery_time(filter_all)
      filtered_stock
    end

    def self.find_with_minimum_delivery_time(jsonData)
      returnData = jsonData[0]
      jsonData.each do |j|
        if returnData['deliveryPeriod'] < j['deliveryPeriod']
          returnData = j
        end
      end
      retArray = []
      retArray << returnData
      retArray
    end

    def self.search_articles_url
      pattern = "/search/articles?"
      url = "#{@partner.url}#{pattern}userlogin=#{@partner.login}&userpsw=#{@partner.pass}&number=#{URI.encode(clear(@sku))}&brand=#{@brand}"
    end

    def self.clear(text)
      if(text.length>0)
        if text.include? '.0'
          text.slice! ".0"
        end
        temp = text.delete(' ').delete('-').delete('.').delete('/')
        text = temp
      end
      text
    end

    def self.product_params(params)
      params.require(:product).permit(permitted_product_attributes)
    end

  end
end