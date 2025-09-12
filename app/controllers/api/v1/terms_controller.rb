# app/controllers/api/v1/terms_controller.rb
module Api
  module V1
    class TermsController < ApplicationController
      # Skip authentication for public terms access
      skip_before_action :authenticate_user!, only: [:index, :show, :current]
      before_action :force_json_format

      def index
        terms = Term.includes(:term)
                   .order(created_at: :desc)
                   
        render json: {
          success: true,
          data: terms.map { |term| serialize_term(term) },
          count: terms.count
        }
      end

      def show
        term = Term.find(params[:id])
        
        render json: {
          success: true,
          data: serialize_term(term, include_content: true)
        }
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          error: 'Terms not found'
        }, status: :not_found
      end

      def current
        term_type = params[:type] || 'terms_of_service'
        
        term = Term.current.find_by(term_type: term_type)
        
        if term
          render json: {
            success: true,
            data: serialize_term(term, include_content: true)
          }
        else
          render json: {
            success: false,
            error: "No current #{term_type.humanize.downcase} found"
          }, status: :not_found
        end
      end

      def create
        ensure_admin
        
        term = Term.new(term_params)
        
        if term.save
          render json: {
            success: true,
            data: serialize_term(term, include_content: true),
            message: 'Terms created successfully'
          }, status: :created
        else
          render json: {
            success: false,
            errors: term.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      def update
        ensure_admin
        
        term = Term.find(params[:id])
        
        if term.update(term_params)
          render json: {
            success: true,
            data: serialize_term(term, include_content: true),
            message: 'Terms updated successfully'
          }
        else
          render json: {
            success: false,
            errors: term.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          error: 'Terms not found'
        }, status: :not_found
      end

      private

      def force_json_format
        request.format = :json
      end

      def ensure_admin
        render json: { 
          success: false,
          error: "Access denied" 
        }, status: :forbidden unless current_user&.has_role?(:admin)
      end

      def term_params
        params.require(:term).permit(
          :title, :content, :version, :term_type, :active, 
          :summary, :effective_date
        )
      end

      def serialize_term(term, include_content: false)
        result = {
          id: term.id,
          title: term.title,
          version: term.version,
          term_type: term.term_type,
          active: term.active,
          summary: term.summary,
          effective_date: term.effective_date&.iso8601,
          created_at: term.created_at.iso8601,
          updated_at: term.updated_at.iso8601
        }
        
        result[:content] = term.content if include_content
        result
      end
    end
  end
end