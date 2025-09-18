# app/controllers/api/v1/contacts_controller.rb
module Api
  module V1
    class ContactsController < ApplicationController
      before_action :authenticate_user!
      
      # Force JSON responses for all actions
      respond_to :json

      # POST /api/v1/contacts/check_registered
      def check_registered
        begin
          phone_numbers = params[:phone_numbers]
          
          Rails.logger.info "ContactsController#check_registered called with #{phone_numbers&.length || 0} phone numbers"
          
          # Validate input
          unless phone_numbers.is_a?(Array) && phone_numbers.present?
            Rails.logger.warn "Invalid phone_numbers parameter: #{phone_numbers.inspect}"
            render json: {
              success: false,
              message: 'Phone numbers array is required'
            }, status: :bad_request
            return
          end

          # Limit the number of phone numbers to prevent abuse
          if phone_numbers.length > 1000
            Rails.logger.warn "Too many phone numbers: #{phone_numbers.length}"
            render json: {
              success: false,
              message: 'Maximum 1000 phone numbers allowed per request'
            }, status: :bad_request
            return
          end

          Rails.logger.info "Processing #{phone_numbers.length} phone numbers for registration check"

          # Step 1: Safely normalize input phone numbers
          normalized_numbers = safely_normalize_numbers(phone_numbers)
          Rails.logger.info "Successfully normalized #{normalized_numbers.length} phone numbers"

          # Step 2: Find registered numbers using defensive approach
          registered_numbers = find_registered_numbers_safely(normalized_numbers)
          Rails.logger.info "Found #{registered_numbers.length} registered phone numbers"

          render json: {
            success: true,
            registered_numbers: registered_numbers,
            total_checked: normalized_numbers.length,
            registered_count: registered_numbers.length
          }, status: :ok

        rescue ActiveRecord::ConnectionTimeoutError => e
          Rails.logger.error "Database timeout error: #{e.message}"
          render json: {
            success: false,
            message: 'Database connection timeout - please try again'
          }, status: :service_unavailable

        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.error "Database query error: #{e.message}"
          render json: {
            success: false,
            message: 'Database query failed - please try again'
          }, status: :internal_server_error

        rescue StandardError => e
          Rails.logger.error "ContactsController#check_registered error: #{e.class}: #{e.message}"
          Rails.logger.error "Backtrace: #{e.backtrace.first(10).join("\n")}"
          
          render json: {
            success: false,
            message: 'Failed to check registered contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/contacts/my_contacts (optional - for syncing contact list to server)
      def my_contacts
        begin
          render json: {
            success: true,
            message: 'Contact sync feature coming soon',
            contacts: []
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error "ContactsController#my_contacts error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to fetch contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/contacts/sync (optional - for syncing user's contacts to server)
      def sync
        begin
          render json: {
            success: true,
            message: 'Contact sync feature coming soon'
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error "ContactsController#sync error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to sync contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      private

      # Safely normalize an array of phone numbers with comprehensive error handling
      def safely_normalize_numbers(phone_numbers)
        normalized = []
        
        phone_numbers.each_with_index do |number, index|
          begin
            next if number.blank?
            
            normalized_number = normalize_phone_number_kenyan(number.to_s)
            if normalized_number
              normalized << normalized_number
              Rails.logger.debug "Normalized [#{index}]: '#{number}' -> '#{normalized_number}'"
            else
              Rails.logger.debug "Failed to normalize [#{index}]: '#{number}' - invalid format"
            end
            
          rescue StandardError => e
            Rails.logger.error "Error normalizing phone number [#{index}] '#{number}': #{e.message}"
            # Continue processing other numbers
            next
          end
        end
        
        normalized.uniq
      end

      # Find registered phone numbers using defensive database queries
      def find_registered_numbers_safely(normalized_numbers)
        return [] if normalized_numbers.empty?
        
        Rails.logger.info "Searching for #{normalized_numbers.length} normalized numbers in database"
        
        # Use direct SQL with parameters to avoid ActiveRecord issues
        registered_phones = []
        
        begin
          # Get all registered phone numbers in batches to handle large datasets
          User.where.not(phone_number: [nil, '']).find_in_batches(batch_size: 1000) do |user_batch|
            batch_phones = user_batch.pluck(:phone_number).compact
            Rails.logger.debug "Processing batch of #{batch_phones.length} phone numbers"
            
            # Normalize each phone number from database safely
            batch_phones.each do |db_phone|
              begin
                normalized_db_phone = normalize_phone_number_kenyan(db_phone)
                if normalized_db_phone && normalized_numbers.include?(normalized_db_phone)
                  registered_phones << normalized_db_phone
                  Rails.logger.debug "Match found: #{db_phone} -> #{normalized_db_phone}"
                end
              rescue StandardError => e
                Rails.logger.error "Error processing database phone number '#{db_phone}': #{e.message}"
                # Continue processing other numbers
                next
              end
            end
          end
          
        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.error "Database query failed: #{e.message}"
          # Fallback to simpler query
          begin
            Rails.logger.info "Attempting fallback query"
            all_phones = User.where.not(phone_number: [nil, '']).limit(10000).pluck(:phone_number)
            
            all_phones.each do |db_phone|
              begin
                normalized_db_phone = normalize_phone_number_kenyan(db_phone)
                if normalized_db_phone && normalized_numbers.include?(normalized_db_phone)
                  registered_phones << normalized_db_phone
                end
              rescue StandardError
                next
              end
            end
            
          rescue StandardError => fallback_error
            Rails.logger.error "Fallback query also failed: #{fallback_error.message}"
            return []
          end
        end
        
        registered_phones.uniq
      end

      # Kenyan-specific phone number normalization - exactly matches User model
      def normalize_phone_number_kenyan(phone_number)
        return nil if phone_number.blank?
        
        begin
          # Remove all non-digit characters except +
          cleaned = phone_number.to_s.gsub(/[^\d\+]/, '')
          
          # Return nil if too short
          return nil if cleaned.length < 9
          
          # Handle Kenyan phone numbers exactly like User model
          case cleaned
          when /^0[17]\d{8}$/
            # Format: 0712345678 -> +254712345678
            "+254#{cleaned[1..-1]}"
          when /^[17]\d{8}$/
            # Format: 712345678 -> +254712345678
            "+254#{cleaned}"
          when /^254[17]\d{8}$/
            # Format: 254712345678 -> +254712345678
            "+#{cleaned}"
          when /^\+254[17]\d{8}$/
            # Format: +254712345678 -> +254712345678 (already correct)
            cleaned
          else
            # Invalid Kenyan format - return nil
            Rails.logger.debug "Invalid Kenyan phone format: #{cleaned}"
            nil
          end
          
        rescue StandardError => e
          Rails.logger.error "Error in normalize_phone_number_kenyan for '#{phone_number}': #{e.message}"
          nil
        end
      end
    end
  end
end