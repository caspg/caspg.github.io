---
layout: post
title: Playing with GPX tracks in Elixir and Postigs
---

Lately, I'm playing with an idea of creating a web app for storing and visualising my cycling rides. Think about something like my own private version of Strava. Most of the popular activity trackers, allow to export your activities as a **GPX** files. We can use those files to import an activity to the other service, for example to the one that we will build in a moment.

In this blog post, I would like to present my findings on how to store and visualize gpx tracks using Elixir/Phoenix, PostgreSQL and little bit of JavaScript. The plan is to parse GPX file and extract track's data. Save it in PostgreSQL as a **geometry** type, which comes with [PostGIS](https://postgis.net/), spatial database extension. Finally, visualize track using [Leaflet.js](https://leafletjs.com/), interactive web map

<br />

## GPX intro

**GPX** (GPS Exchange Format) is an XML data format, designed to share GPS data between software applications. It was developed by company named TopoGrafix. First release was in 2002 and latest, GPX 1.1, in 2004. You can find more info about the format at the [gpx website](https://www.topografix.com/gpx.asp).

GPX can be used to describe following data:
* **waypoints** - individual points without relationship to each other
* **routes** - an ordered list of points, representing series of turns leading to a destination
* **tracks** - an ordered list of points, describing a path, for example a raw output of GPS recording of single trip

Below we can examin an example gpx file. It contains tracks data, which were recorded during an activity.

```xml
<!-- my_activity.xml -->

<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="StravaGPX" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <time>2020-02-02T10:37:13Z</time>
  </metadata>
  <trk> <!-- representation of a track -->
    <name>Gdynia</name>
    <trkseg> <!-- track segment -->
      <trkpt lat="54.5198480" lon="18.5396990"> <!-- track point -->
        <ele>10.2</ele> <!-- point elevation -->
        <time>2020-02-02T10:37:13Z</time> <!-- time of the recording  -->
      </trkpt>

      <trkpt lat="54.5198540" lon="18.5397300">
        <ele>10.2</ele>
        <time>2020-02-02T10:37:14Z</time>
      </trkpt>

      <!-- more track points  -->
    </trkseg>
  </trk>
</gpx>
```

I've created [GpxEx](https://github.com/caspg/gpx_ex) package - elixir gpx parser. It's still work in progress but it supports parsing tracks. After reading gpx file, you can convert it to elixir structs.


```elixir
{:ok, gpx_doc} = File.read("./my_track.gpx")
{:ok, gpx} = GpxEx.parse(gpx_doc)

%GpxEx.Gpx{
  tracks: [
    %GpxEx.Track{
      name: "Track's name",
      segments: [
        %GpxEx.TrackSegment{
          points: [
            %GpxEx.TrackPoint{
              ele: 10.2,
              lat: 54.519848,
              lon: 18.539699,
              time: "2020-02-02T10:37:13Z"
            },
            %GpxEx.TrackPoint{
              ele: 10.2,
              lat: 54.519854,
              lon: 18.53973,
              time: "2020-02-02T10:37:14Z"
            }
          ]
        }
      ]
    }
  ]
}
```

<br />

## PostGIS intro

What is PostGIS and why do we need it? PostgreSQL supports xml data type natively. Why not use that? We could save gpx file straight away and skip the whole parsing part and adding extra extension.

Doing all of that, we would loose many benefits that are provided by [PostGIS](https://postgis.net/features). PostGIS is a spatial database extension that adds support for geographic objects. After converting tracks to geo type and storing them in Postgres, we will be able to run **location queries** and **spatial functions**. For example, we will be able to:

* find all tracks near certain location
* calculate track's distance
* convert track to the format used by web maps (GeoJSON, TopoJSON, KML etc)

<br />

## Intial project setup

In this tutorial I'm usingin following versions:

* Elixir 1.10
* Phoenix 1.4.14
* PostgreSQL 12.2
* PostGIS 3.0

Let's start with creating new Phoenix project.

```bash
mix phx.new gpx_phoenix
cd gpx_phoenix
mix ecto.create
```

<br />

## PostGIS in Phoenix framework

We can use [geo](https://github.com/bryanjos/geo) and [geo_postgis](https://github.com/bryanjos/geo_postgis) packages to enable PostGIS in Phoenix application.

```elixir
defp deps do
  # other deps
  {:geo, "~> 3.3"},
  {:geo_postgis, "~> 3.3"}
end
```

First, we need to pass new PostGIS extensions to [postgrex](https://github.com/elixir-ecto/postgrex). We have to create new file, for exmple `lib/gpx_phoenix/postgrex_extensions.ex`. It has to be defined only once during compilation, hence it needs to be done outside of any module or function.

```elixir
# lib/gpx_phoenix/postgrex_extensions.ex

Postgrex.Types.define(
  GpxPhoenix.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
```

After defining above types, we need to specify them in our `Repo` config.

```elixir
# config/config.exs

config :gpx_phoenix, GpxPhoenix.Repo,
  types: GpxPhoenix.PostgresTypes
```

Last step is to actually enable PostGIS in PostgreSQL.

```elixir
defmodule GpxPhoenix.Repo.Migrations.EnablePostgisExtension do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS postgis"
  end
end
```

<br />

## Tracks context

In this section, we are creating `Tracks` context. We have to generate migration which will create tracks table with two columns. `geom` column will hold geometry of each track. We can create it using `AddGeometryColumn` function provided by PostGIS.

```sql
-- AddGeometryColumn(table_name, column_name, srid, type, dimension);
SELECT AddGeometryColumn('tracks', 'geom', 3857, 'MULTILINESTRINGZ', 3);
```

The `sird` stands for spatial reference system identifier which defines coordinate system. We are going to use Pseudo-Mercator (EPSG:3857) used for rendering most of the popular web maps. The `type` specifies geometry type, eg, 'POLYGON', 'POINT'. `MULTILINESTRINGZ` is a multi line string type that allows to define elevation of each point. Last argument is the `dimension`, we want to store 3 dimensions, we want to store x and y coordinates along with elevation (z).

```elixir
# priv/repo/migrations/20200316162637_create_tracks_table.exs

defmodule GpxPhoenix.Repo.Migrations.CreateTracksTable do
  use Ecto.Migration

  def up do
    create table(:tracks) do
      add(:name, :string)

      timestamps()
    end

    execute("SELECT AddGeometryColumn('tracks', 'geom', 3857, 'MULTILINESTRINGZ', 3);")
  end

  def down do
    drop table(:tracks)
  end
end

```

In track's schema we can just use `Geo.PostGIS.Geometry` type which was added by `geo_postigs` package, but we have to remember that we specified our geometry type as `MULTILINESTRINGZ`.

```elixir
# lib/gpx_phoenix/tracks/track.ex

defmodule GpxPhoenix.Tracks.Track do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracks" do
    field(:name, :string)
    field(:geom, Geo.PostGIS.Geometry)

    timestamps()
  end

  @doc false
  def changeset(track, attrs) do
    track
    |> cast(attrs, [:name, :geom])
    |> validate_required([:name, :geom])
  end
end
```

Tracks context with basic CRUD functions.

```elixir
# lib/gpx_phoenix/tracks/tracks.ex

defmodule GpxPhoenix.Tracks do
  @moduledoc """
  The Tracks context.
  """

  import Ecto.Query, warn: false
  alias GpxPhoenix.Repo

  alias GpxPhoenix.Tracks.Track

  def get_track!(id), do: Repo.get!(Track, id)

  def list_tracks, do: Repo.all(Track)

  def create_track(attrs \\ %{}) do
    %Track{}
    |> Track.changeset(attrs)
    |> Repo.insert()
  end

  def change_track(%Track{} = track), do: Track.changeset(track, %{})
end
```

<br />

## Tracks importer

Now we can focus on track importer module. It will be responsible for parsing gpx and creating new track's record. We will parse gpx file using [GpxEx](https://github.com/caspg/gpx_ex) package which we have to add to our dependencies.

```elixir
# mix.exs

defp deps do
  # other deps
  {:gpx_ex, git: "git@github.com:caspg/gpx_ex.git", tag: "0.1.0"}
end
```

Before saving parsed gpx file to the databse, we have to convert it to our geometry type, which is `Geo.MultiLineStringZ`. When creating Geo type, we have to use the same `srid` value as we used during creating `geom` column.

```elixir
# lib/gpx_phoenix/tracks/import_track.ex

defmodule GpxPhoenix.Tracks.ImportTrack do
  alias GpxPhoenix.Tracks.Track

  @spec call(gpx_doc: String.t()) :: {:error, %Ecto.Changeset{}} | {:ok, %Track{}}

  def call(gpx_doc) do
    gpx_doc
    |> GpxEx.parse()
    |> get_first_track()
    |> build_track_geometry()
    |> create_track()
  end

  defp get_first_track({:ok, %GpxEx.Gpx{tracks: [track | _]}}), do: {:ok, track}

  defp build_track_geometry({:ok, %GpxEx.Track{segments: segments} = track}) do
    multilinez_coordinates = convert_segments_to_mulitlinez(segments)

    track_geometry = %Geo.MultiLineStringZ{
      coordinates: multilinez_coordinates,
      srid: 3857
    }

    {:ok, track, track_geometry}
  end

  defp convert_segments_to_mulitlinez(segments) do
    Enum.map(segments, fn segment ->
      Enum.map(segment.points, fn point ->
        {point.lon, point.lat, point.ele}
      end)
    end)
  end

  defp create_track({:ok, %GpxEx.Track{name: name}, track_geometry}) do
    GpxPhoenix.Tracks.create_track(%{name: name, geom: track_geometry})
  end
end
```

Let's import some example gpx files. Here are three tracks of my recent activities [https://github.com/caspg/gpx_phoenix/tree/master/gpx_files](https://github.com/caspg/gpx_phoenix/tree/master/gpx_files). We can import them using elixir console.

```bash
iex -S mix

iex(1)> {:ok, gpx_doc} = File.read("./gpx_files/gdansk-elblag.gpx")
iex(2)> GpxPhoenix.Tracks.ImportTrack.call(gpx_doc)

# same for othe files
```

<br />

## Converting track to GeoJSON

[GeoJSON](https://en.wikipedia.org/wiki/GeoJSON) format is designed to represent geographical objects and is based on the JSON. It is commonly used in web mapping applications. We can easily convert our geometry to GeoJSON using PostGIS function.

```elixir
# lib/gpx_phoenix/tracks/tracks.ex

defmodule GpxPhoenix.Tracks do
  import Ecto.Query, warn: false
  alias GpxPhoenix.Repo
  alias GpxPhoenix.Tracks.Track

  # ...other functions

  def get_geom_as_geojson!(%{id: id}) do
    query =
      from(t in Track,
        where: t.id == ^id,
        select: fragment("ST_AsGeoJSON(?)::json", t.geom)
      )

    Repo.one!(query)
  end
end
```

<br />

## Tracks controller

We need to create `tracks_controller`, `tracks_view` and corresponding templates. `tracks_controller` will have two standard CRUD actions and one action for fetching track's GeoJSON asynchronously.

```elixir
defmodule GpxPhoenixWeb.Router do
  # omitted code

 scope "/", GpxPhoenixWeb do
    pipe_through :browser

    get "tracks", TracksController, :index
    get "tracks/:id", TracksController, :show
    get "tracks/:id/geojson", TracksController, :geojson
  end
end
```

```elixir
# lib/gpx_phoenix_web/controllers/tracks_controller.ex

defmodule GpxPhoenixWeb.TracksController do
  use GpxPhoenixWeb, :controller

  def index(conn, _params) do
    tracks = GpxPhoenix.Tracks.list_tracks()
    render(conn, "index.html", tracks: tracks)
  end

  def show(conn, %{"id" => id} = _params) do
    track = GpxPhoenix.Tracks.get_track!(id)
    render(conn, "show.html", track: track)
  end

  def geojson(conn, %{"id" => id} = _params) do
    geojson = GpxPhoenix.Tracks.get_geom_as_geojson!(%{id: id})

    json(conn, geojson)
  end
end
```


```elixir
# lib/gpx_phoenix_web/views/tracks_view.ex

defmodule GpxPhoenixWeb.TracksView do
  use GpxPhoenixWeb, :view
end
```

```html
# lib/gpx_phoenix_web/templates/tracks/index.html.eex

<ul>
  <%= for track <- @tracks do %>
    <li>
      <%= link(track.name, to: Routes.tracks_path(@conn, :show, track.id)) %>
    </li>
  <% end %>
</ul>
```

```html
# lib/gpx_phoenix_web/templates/tracks/show.html.eex

<h2><%= @track.name %></h2>
```

<br />

## Interactive web map

We will use [Leaflet.js](https://leafletjs.com/) to render interactive web map. Before writing any JavaScript code we have to include Leaflet CSS and Leaflet JavaScript files. To make things simpler we can include those files in `show` template.

We also need a html element which will serve as a container for our map and will hold `track-id` as data attribute. We will need `track-id` to fetch correct geojson.

```html
# lib/gpx_phoenix_web/templates/tracks/show.html.eex

<h2><%= @track.name %></h2>

<div id="track-map" style="height: 500px; margin-top: 50px;" data-track-id="<%= @track.id %>"></div>

<link rel="stylesheet" href="https://unpkg.com/leaflet@1.6.0/dist/leaflet.css" />
<script src="https://unpkg.com/leaflet@1.6.0/dist/leaflet.js"></script>
```

TODO
Create Leaflet map, fetch geojson and add it to the map, use leaflet functionality to fit track to the bound
TODO

```js
// assets/js/app.js

function renderMap() {
  const trackMap = document.getElementById('track-map')

  if (!trackMap) {
    return
  }

  // create leaflet map object
  const map = L.map('track-map');

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
  }).addTo(map);

  // fetch geojson and add it to the map
  const trackId = trackMap.dataset.trackId

  fetch(`/tracks/${trackId}/geojson`)
    .then((res) => res.json())
    .then((geojson) => {
      const geojsonLayer = L.geoJSON(geojson).addTo(map);

      // handy function that makes sure our track will fit the map
      map.fitBounds(geojsonLayer.getBounds());
    });
}

renderMap()
```

<br />

![Track 1](/assets/images/posts/gpx-tracks-in-elixir-and-postigs/1.png)
![Track 2](/assets/images/posts/gpx-tracks-in-elixir-and-postigs/2.png)
