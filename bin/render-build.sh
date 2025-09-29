#!/usr/bin/env bash
# exit on error
set -o errexit

bundle install

# ./bin/rails assets:precompile
# ./bin/rails assets:clean


# echo "=== Dropping and Creating Database ==="
# bundle exec rails db:drop #DISABLE_DATABASE_ENVIRONMENT_CHECK=1 || true
bundle exec rails db:create
bundle exec rails generate rolify Role User
#bundle exec rails generate migration #AddPackageSizeToPrices package_size:string
#bundle exec rails db:migrate:down VERSION=20250908135959

bundle exec rails db:migrate
bundle exec rails active_storage:install

bundle exec rails assets:precompile 
bundle exec rails assets:clean

rake conversations:merge_duplicates
rake messages:backfill_acknowledgments

echo "=== Seeding Test Data ==="
bundle exec rails db:seed


#bin/rails db:migrate

 

echo "=== Build Complete Successfully ==="

#  bundle install; bundle exec rails assets:precompile; bundle exec rails assets:clean;