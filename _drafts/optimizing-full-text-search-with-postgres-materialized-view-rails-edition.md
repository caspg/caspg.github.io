---
layout: post
title: Optimizing full text search with Postgres materialized view - Rails edition
---

TODO: intro

1. problem
2. short intro about full test search
3. possible solutions (materialized view, triggers etc)
4. why materialized view

## Schema

~~Below you can find models and simplified schema information. DB design is rather simple. `:job_post` belongs to `:company` and has many `:skills` through `:job_post_skills` join table.~~

<br/>

```ruby
class CreateJobPostsSkillsAndCompanies < ActiveRecord::Migration
  def change
    create_table :companies do |t|
      t.string :name
    end

    create_table :job_posts do |t|
      t.string :title
      t.text :description
      t.belongs_to :company

      t.timestamps
    end

    create_table :skills do |t|
      t.string :name

      t.timestamps
    end

    create_table :job_post_skills do |t|
      t.belongs_to :skill
      t.belongs_to :job_post

      t.timestamps
    end
  end
end
```

<br/>

## Seed data

Let’s create some seed data. 10_000 job posts should be enough.

```ruby
# db/seed.rb
spacex = Company.create(name: 'spacex')
tesla = Company.create(name: 'tesla')

ruby_skill = Skill.create(name: 'ruby')
postgres_skill = Skill.create(name: 'postgres')

random_skills = (0...5).map { Skill.create(name: SecureRandom.hex(5)) }

6000.times do
  job_post = JobPost.create!(
    company: spacex,
    title: 'Senior Ruby on Rails developer',
    description: 'Ruby on Rails, or Rails, is a server-side web application framework written in Ruby under the MIT License.',
  )

  JobPostSkill.create(job_post: job_post, skill: ruby_skill)
  random_skills.each { |skill| JobPostSkill.create(job_post: job_post, skill: skill) }
end

4000.times do
  job_post = JobPost.create!(
    company: tesla,
    title: 'Software Engineer',
    description: 'Elixir is a functional, concurrent, general-purpose programming language that runs on the Erlang virtual machine.',
  )

  JobPostSkill.create(job_post: job_post, skill: postgres_skill)
  random_skills.each { |skill| JobPostSkill.create(job_post: job_post, skill: skill) }
end
```

## Full text search in Rails using `pg_search` gem

First we need to add below line to the Gemfile.

```ruby
gem 'pg_search'
```

After that we can configure a search scope using `pg_search_scope`. The first parameter is a scope that we will be using for full text search ([docs](https://github.com/Casecommons/pg_search#pg_search_scope)).

We want to search not only against columns in `JobPost` but also against columns on associated models, `Skill` and `Company`. Fortunatelly for us, `pg_search` gives us `:associated_against` options which supports searching through associations.

```ruby
class JobPost < ApplicationRecord
has_many :job_post_skills, dependent: :destroy
  has_many :skills, through: :job_post_skills
  belongs_to :company

  include PgSearch::Model
  pg_search_scope(
    :search,
    against: [:title, :description],
    associated_against: { skills: :name, company: :name },
    using: {
      tsearch: {
        dictionary: 'english',
      },
    },
  )
end
```

TODO: run search in console and show

```bash
2.6.5 :017 > JobPost.search("ruby on rails")
JobPost Load (738.5ms)  SELECT  "job_posts".* FROM "job_posts" ...
```

TODO: what is going on
* search document
* show tsv document

TODO: how to optimize
* indexes
* normalized data, triggers etc vs materialized view

TODO: materialized view intro
* what is postgresql view
* what is a difference between normal and materialized view

TODO: add scenic gem and scenic related code

```ruby
gem 'scenic'
```

```bash
rails generate scenic:view job_post_search --materialized
```

<!-- GENERATED: -->

```sql
-- db/views/job_post_searches_v01.sql

SELECT
  job_posts.id AS job_post_id,
  (
    to_tsvector('english', coalesce(job_posts.title, ''))
    || to_tsvector('english', coalesce(job_posts.description, ''))
    || to_tsvector('english', coalesce(companies.name, ''))
    || to_tsvector('english', coalesce(string_agg(skills.name, ' ; '), ''))
  ) AS tsv_document
FROM job_posts
JOIN companies ON companies.id = job_posts.company_id
JOIN job_post_skills ON job_post_skills.job_post_id = job_posts.id
JOIN skills ON skills.id = job_post_skills.skill_id
GROUP BY job_posts.id, companies.id;
```

This will create materialized view with two columns, `job_post_id` and `tsv_document`.
TODO: GIN vs other postgres index

```ruby
class CreateJobPostSearches < ActiveRecord::Migration
  def change
    create_view :job_post_searches, materialized: true
    # let's add below index
    add_index :job_post_searches, :tsv_document, using: :gin
  end
end
```

```ruby
class JobPostSearch < ApplicationRecord
  self.primary_key = :job_post_id

  include PgSearch::Model
  pg_search_scope(
    :search,
    against: :tsv_document,
    using: {
      tsearch: {
        dictionary: 'english',
        tsvector_column: 'tsv_document',
      },
    },
  )
  def readonly?
    true
  end
end
```

TODO: show faster search

```bash
2.6.5 :01 > JobPost.search("ruby on rails")
JobPost Load (738.5ms)  SELECT  "job_posts".* FROM "job_posts" ...

2.6.5 :02 > JobPost.faster_search("ruby on rails")
JobPost Load (19.3ms)  SELECT  "job_posts".* FROM "job_posts" ...
```

TODO: how to refresh materialized view
