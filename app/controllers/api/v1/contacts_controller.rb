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
          
          Rails.logger.info "ContactsController#check_registered called with params: #{params.inspect}"
          
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

          Rails.logger.info "Checking #{phone_numbers.length} phone numbers for registration status"

          # Clean and normalize phone numbers using unified logic
          normalized_numbers = phone_numbers.map do |number|
            normalize_phone_number(number.to_s)
          end.compact.uniq

          Rails.logger.info "Normalized to #{normalized_numbers.length} unique phone numbers: #{normalized_numbers.inspect}"

          # Find registered users using database-agnostic approach
          registered_numbers = find_registered_numbers(normalized_numbers, phone_numbers)

          Rails.logger.info "Found #{registered_numbers.length} registered phone numbers"

          render json: {
            success: true,
            registered_numbers: registered_numbers,
            total_checked: normalized_numbers.length,
            registered_count: registered_numbers.length
          }, status: :ok

        rescue => e
          Rails.logger.error "ContactsController#check_registered error: #{e.message}"
          Rails.logger.error "Error class: #{e.class}"
          Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
          
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
          # Get current user's contacts if they've synced them
          # This could be useful for features like "People you may know"
          
          render json: {
            success: true,
            message: 'Contact sync feature coming soon',
            contacts: []
          }, status: :ok

        rescue => e
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
          # This endpoint could be used to sync user's contacts to the server
          # for features like "Find friends" or contact recommendations
          
          render json: {
            success: true,
            message: 'Contact sync feature coming soon'
          }, status: :ok

        rescue => e
          Rails.logger.error "ContactsController#sync error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to sync contacts',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      private

      # Database-agnostic method to find registered phone numbers
      def find_registered_numbers(normalized_numbers, original_numbers)
        # Get all registered users' phone numbers
        all_registered_phones = User.where.not(phone_number: [nil, '']).pluck(:phone_number)
        
        Rails.logger.info "Found #{all_registered_phones.length} users with phone numbers"
        
        # Normalize all registered phone numbers for comparison
        registered_normalized = all_registered_phones.map { |phone| normalize_phone_number(phone) }.compact
        
        Rails.logger.info "Normalized registered phones: #{registered_normalized.inspect}"
        
        # Find matches between input and registered numbers
        matches = []
        
        # Check normalized numbers
        normalized_numbers.each do |norm_input|
          if registered_normalized.include?(norm_input)
            matches << norm_input
          end
        end
        
        # Also check original input formats against registered numbers (for edge cases)
        original_numbers.each do |orig_input|
          normalized_orig = normalize_phone_number(orig_input.to_s)
          if normalized_orig && registered_normalized.include?(normalized_orig) && !matches.include?(normalized_orig)
            matches << normalized_orig
          end
        end
        
        Rails.logger.info "Final matches: #{matches.inspect}"
        
        matches.uniq
      end

      # Unified phone number normalization - matches User model exactly
      def normalize_phone_number(phone_number)
        return nil if phone_number.blank?
        
        # Remove all non-digit characters except +
        cleaned = phone_number.gsub(/[^\d\+]/, '')
        
        Rails.logger.debug "Normalizing: '#{phone_number}' -> cleaned: '#{cleaned}'"
        
        # Handle Kenyan phone numbers (exact match to User model logic)
        if cleaned.match(/^0[17]\d{8}$/) # 0712345678
          "+254#{cleaned[1..-1]}"
        elsif cleaned.match(/^[17]\d{8}$/) # 712345678
          "+254#{cleaned}"
        elsif cleaned.match(/^254[17]\d{8}$/) # 254712345678
          "+#{cleaned}"
        elsif cleaned.match(/^\+254[17]\d{8}$/) # +254712345678
          cleaned
        else
          # For non-Kenyan numbers, keep original cleaned format
          cleaned.presence
        end
      end
    end
  end
end