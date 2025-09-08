# app/controllers/api/v1/categories_controller.rb
module Api
  module V1
    class CategoriesController < ApplicationController
      before_action :authenticate_user!, except: [:index]

      def index
        categories = Category.active.alphabetical

        render json: {
          success: true,
          data: categories.map do |category|
            {
              id: category.id,
              name: category.name,
              slug: category.slug,
              description: category.description,
              business_count: category.businesses.count
            }
          end,
          meta: {
            total_count: categories.count,
            active_count: Category.active.count,
            inactive_count: Category.where(active: false).count
          }
        }, status: :ok
      end

      def show
        category = Category.find_by(slug: params[:id]) || Category.find(params[:id])
        
        if category&.active?
          businesses = category.businesses.includes(:owner, :categories)
          
          render json: {
            success: true,
            data: {
              category: {
                id: category.id,
                name: category.name,
                slug: category.slug,
                description: category.description
              },
              businesses: businesses.map do |business|
                {
                  id: business.id,
                  name: business.name,
                  phone_number: business.phone_number,
                  owner_name: business.owner.name,
                  categories: business.categories.active.pluck(:name)
                }
              end
            },
            meta: {
              business_count: businesses.count
            }
          }, status: :ok
        else
          render json: {
            success: false,
            message: "Category not found"
          }, status: :not_found
        end
      end
    end
  end
end