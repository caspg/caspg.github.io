---
layout: post
title: Optimizing full-text search with Postgres materialized view in Rails
---

My recent side project is an aggregator for remote dev jobs [https://remotestack.club](https://remotestack.club). To keep things simple, I decided to use Postgres full-text search. It offers powerful search capabilities. More than enough for a side project and early startups.

I built the project with **Ruby on Rails** and I used **pg_search** gem to handle PostgreSQL's full-text search. I wanted to offer a search across the job's details, skills' names, and the company's name.

It is easy to search columns on associated models. Unfortunately, there is no simple solution to speed up those searches. This article shows how to optimize search with Postgres materialized view.

### Quick intro to full-text search

Full-text search is a technique for searching natural-language **documents** that satisfy a query.
In our case, a query is a text provided by a user.

> A **document** is the unit of searching in a full text search system; for example, a magazine article or email message

<p style="text-align: end;">
  <a href="https://www.postgresql.org/docs/9.3/textsearch-intro.html">
    <small>Postgres text search intro</small>
  </a>
</p>

In PostgreSQL, a document usually is a text field or a combination of fields. Possibly stored across multiple tables. During the search, each document is converted into **tsvector**.

> A **tsvector** value is a sorted list of distinct lexemes, which are words that have been normalized to merge different variants of the same word

<p style="text-align: end;">
  <a href="https://www.postgresql.org/docs/9.4/datatype-textsearch.html">
    <small>Text search data types</small>
  </a>
</p>

Below we can see a **tsvector** in action.

```
postgres=# SELECT to_tsvector('Ruby on Rails, is a server-side web application framework');
                                       to_tsvector
-----------------------------------------------------------------------------------------
 'applic':10 'framework':11 'rail':3 'rubi':1 'server':7 'server-sid':6 'side':8 'web':9
(1 row)
```

<br/>

## Schema

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

[https://github.com/caspg/optimizing-postgresql-full-text-search-rails/blob/master/db/seeds.rb](https://github.com/caspg/optimizing-postgresql-full-text-search-rails/blob/master/db/seeds.rb)

<br/>

## Full text with `pg_search` gem

[Pg_search gem](https://github.com/Casecommons/pg_search) builds ActiveRecord named scopes that take advantage of PostgreSQL's full-text search. We can configure a search scope using `pg_search_scope`. The first parameter is a scope that we will use for full-text search.

We want to search against columns in `JobPost` but also against columns on associated models, `Skill` and `Company`. `pg_search` supports searching through associations with `:associated_against` options.

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

After adding a couple of lines of code, we can already use a full-text search. As we can see below, performance is not that great.

```bash
> JobPost.search("ruby on rails")
JobPost Load (1076.5ms)  SELECT  "job_posts".* FROM "job_posts" ...
```

<br/>

## Potential optimizations

We can use database indexes to speed up data retrieval. Postgres gives us two types of indexes for full-text searches.

* **GIN** (Generalized Inverted Index)
* **GiST** (Generalized Search Tree)

Acording to the [documentation](https://www.postgresql.org/docs/12/textsearch-indexes.html), GIN indexes are the preferred type.

```sql
CREATE INDEX name ON table USING GIN (column);
-- or
CREATE INDEX name ON table USING GIN (to_tsvector('english', column));
```

The column must be of `tsvector` type or must be converted to this type with `to_tsvector` function. We can  populate the column of tsvector type using database triggers. With searches across associated tables, we have to do some extra work to build such indexes.

We could use database **denormalization** and triggers to ensure data integrity. This would give us up to date indexes but would introduce extra complexity and would slow down updates. Another solution is **materialized view**.

<br/>

## Quick intro to materialized views

A **View** is a virtual table created by a query based on one or more tables. It can be used for wrapping commonly used complex queries. **Materialized Views** are special kind of **View** that persist results in table-like form.

They give us faster access to data but increase database size and data are not always current. They are perfect in scenarios when data does not have to be always fresh or when we have more or less static data. For example, a job aggregator which imports new posts a couple of times per day. In this case, we can refresh data after each import.

We can generate fresh data with:

```sql
REFRESH MATERIALIZED VIEW my_materialized_view;
```

<br/>

## Materialized views in Rails with Scenic gem

[Scenic](https://github.com/scenic-views/scenic) gem adds methods to create and manage database views (and materialized views) in Rails.

```bash
rails generate scenic:view job_post_search --materialized
      create  db/views/job_post_searches_v01.sql
      create  db/migrate/[TIMESTAMP]_update_job_post_searches_to_version_1.rb
```

`job_post_searches_v01.sql` defines a query we will use to build a materialized view. We have to build a view with two columns, `job_post_id` and `tsv_document`.  `tsv_document` is a combination of associated fields in `tsvector` data type.

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

The above query returns the following results:

```
 job_post_id |                                                                                                            tsv_document
-------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
           1 | 'applic':17 'block':31 'dach':30 'develop':5 'framework':18 'licens':25 'mit':24 'parker':28 'rail':4,8,10 'rubi':2,6,21,32 'senior':1 'server':14 'server-sid':13 'side':15 'smith':27 'spacex':26 'von':29 'web':16 'written':19

...more rows
```

`Scenic` adds `create_view` method. It creates a materialized view based on the corresponding SQL statement. Finally, we can also create a GIN index on `tsv_document` column.

```ruby
class CreateJobPostSearches < ActiveRecord::Migration
  def change
    create_view :job_post_searches, materialized: true

    # below line added by us
    add_index :job_post_searches, :tsv_document, using: :gin
  end
end
```

<br/>

## Full-text search using materialized view

Thanks to ActiveRecord, a model can be backed by a view. We can define search scope on such model in the same way we did with `JobPost` model. This time, we want to search against tsvector type column, instead of using an expression (which is used by default). It won't create tsvector during each search and will use a previously created index.

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
        # specify tsvector column name
        tsvector_column: 'tsv_document',
      },
    },
  )
end

class JobPost < ApplicationRecord
  ... # omitted lines

  def self.faster_search(query)
    # protip: when using `select` instead of `pluck` we have one query less
    where(id: JobPostSearch.search(query).select(:job_post_id))
  end
end
```

<br/>

## Results

```bash
> JobPost.search("ruby on rails")
JobPost Load (1076.5ms)  SELECT  "job_posts".* FROM "job_posts" ...

> JobPost.faster_search("ruby on rails")
JobPost Load (1.2ms)  SELECT  "job_posts".* FROM "job_posts" ...
```

<br/>

## Refreshing materialied view

There is one more thing that we will have to take care of. We will have to refresh the materialized view periodically. Scenic gives us a handy method to do that.

When the refresh is running in nonconcurrent mode, the view is locked for selects. We can avoid that with the concurrent mode. The concurrent mode requires at least PostgreSQL 9.4 and view to have at least one unique index that covers all rows.

```ruby
class JobPostSearch < ApplicationRecord
  ... # omitted lines

  def self.refresh_materialized_view
    Scenic.database.refresh_materialized_view(
      :job_post_searches,
      concurrently: true,
    )
  end
end
```

We can add an index to our view as to any other table.

```ruby
class AddUniqueIndexToJobPostSerches < ActiveRecord::Migration
  def change
    add_index :job_post_searches, :job_post_id, unique: true
  end
end
```

Now we can run the below method when we want to generate fresh data.

```bash
> JobPostSearch.refresh_materialized_view
(1411.2ms)  REFRESH MATERIALIZED VIEW CONCURRENTLY "job_post_searches";
```

<br/>

## Comments

If you have any comments, you can reach me via email or twitter.

## Links

* [https://twitter.com/thecaspg/status/1234805333048123392](https://twitter.com/thecaspg/status/1234805333048123392)
* [RemoteStack.club](https://remotestack.club/)
* [GitHub repo](https://github.com/caspg/optimizing-postgresql-full-text-search-rails) containing code example used in this blogpost
