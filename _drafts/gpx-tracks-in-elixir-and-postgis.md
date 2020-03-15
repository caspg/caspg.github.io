---
layout: post
title: Playing with GPX tracks in Elixir and Postigs
---

Lately, I'm playing with an idea of creating a web app for storing and visualising my cycling rides. Think about something like my own private version of Strava. Most of the popular activity trackers, allow to export your activities as a **GPX** files. We can use those files to import an activity to the other service, for example to the one that we will build in a moment.

In this blog post, I would like to present my findings on how to accomplish that using Elixir/Phoenix and PostgreSQL. The plan is to parse GPX file and extract track's data. Save it in PostgreSQL as a **geometry** type, which comes with [PostGIS](https://postgis.net/), spatial database extension. Finally, visualize track using [Leaflet.js](https://leafletjs.com/), interactive web map

<br />

## Quick intro to GPX files

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

<br />

## GPX parsing in Elixir

As a first step, we should parse GPX file and convert it into elixir structs. Of course, instead of structs we could just use generic maps, but structs will help with code readability and maintainability.

```elixir
defmodule Gpx do
  defstruct tracks: nil
end

defmodule Track do
  defstruct segments: nil, name: nil
end

defmodule TrackSegment do
  defstruct points: nil
end

defmodule TrackPoint do
  defstruct lat: nil, lon: nil, ele: nil, time: nil
end
```

GPX is just an XML file and thanks to that we can use [sweet_xml](https://github.com/kbrw/sweet_xml) package which is a xml parser. It gives us a function for extracting desired data using [xpaths](https://en.wikipedia.org/wiki/XPath). For example, `xpath(xml, ~x"//trk"l)` returns list of `trk` elements. Each element can be again passed to `xpath` function to find further details. You can also specify different return values. For now, we will just use:

* `xpath(xml, ~x"//trk"l)` - list of xml elements
* `xpath(xml, ~x"./name/text()"s` - string
* `xpath(xml, ~x"./@lat"f)` - float

Let's create our parser using earlier structs.

```elixir
defmodule Parser do
  import SweetXml

  def parse(gpx_document) do
    tracks =
      gpx_document
      |> get_track_elements()
      |> Enum.map(&build_track/1)

    {:ok, %Gpx{tracks: tracks}}
  end

  defp build_track(track_xml_element) do
    segments =
      track_xml_element
      |> get_segment_elements()
      |> Enum.map(&build_segment/1)

    track_name = get_track_name(track_xml_element)

    %Track{segments: segments, name: track_name}
  end

  defp build_segment(segment_xml_element) do
    points =
      segment_xml_element
      |> get_point_elements()
      |> Enum.map(&build_trackpoint/1)

    %TrackSegment{points: points}
  end

  defp build_trackpoint(point_element) do
    %TrackPoint{
      lat: get_lat(point_element),
      lon: get_lon(point_element),
      ele: get_ele(point_element),
      time: get_time(point_element)
    }
  end

  # returns value as a list of xml elements
  defp get_track_elements(xml), do: xpath(xml, ~x"//trk"l)
  defp get_segment_elements(xml), do: xpath(xml, ~x"./trkseg"l)
  defp get_point_elements(xml), do: xpath(xml, ~x"./trkpt"l)

  # returns value as a string
  defp get_track_name(xml), do: xpath(xml, ~x"./name/text()"s)
  defp get_time(xml), do: xpath(xml, ~x"./time/text()"s)

  # returns value as a float
  defp get_lat(xml), do: xpath(xml, ~x"./@lat"f)
  defp get_lon(xml), do: xpath(xml, ~x"./@lon"f)
  defp get_ele(xml), do: xpath(xml, ~x"./ele/text()"f)
end
```

Now we can read gpx file and pass it to the parser.

```elixir
{:ok, gpx_doc} = File.read("./my_track.gpx")
{:ok, gpx} = Parser.parse(gpx_doc)

%Gpx{
  tracks: [
    %Track{
      name: "Track's name",
      segments: [
        %TrackSegment{
          points: [
            %TrackPoint{
              ele: 10.2,
              lat: 54.519848,
              lon: 18.539699,
              time: "2020-02-02T10:37:13Z"
            },
            %TrackPoint{
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

Instead of writing your own parser, you can use package that I've created recently. It's still work in progress and for now it only supports parsing tracks. Repo can be found here [https://github.com/caspg/gpx_ex](https://github.com/caspg/gpx_ex).

<br />

## Storing GPX tracks in database

PostgreSQL supports xml data type natively. Why not use that? We could save gpx file straight away and skip the whole parsing part. Then, we could use leaflet plugin for displaying gpx tracks and finish our task without much hassle.

Doing all of that, we would loose many benefits that are provided by [PostGIS](https://postgis.net/features). After converting tracks to geo type and storing them in Postgres, we will be able to:

* run location queries in SQL - find all tracks near certain location
* use spatial functions - calculate track's distance
* convert track to the format used by web maps (GeoJSON, TopoJSON, KML etc) - no need for extra javascript plugins

<br />

## PostGIS extension in Phoenix framework

We can use [geo](https://github.com/bryanjos/geo) and [geo_postgis](https://github.com/bryanjos/geo_postgis) package to enable PostGIS in Phoenix applications.

```elixir
# mix.exs

defp deps do
  {:geo, "~> 3.3"},
  {:geo_postgis, "~> 3.3"}
end
```

First, we need to pass new postgis extentions to postgrex types. We can create new file to accomplish that.

```elixir
# lib/gpx_phoenix/postgrex_extensions.ex

Postgrex.Types.define(
  GpxPhoenix.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
```

and pass those types to our Repo config.

```elixir
# config/config.exs

config :gpx_phoenix, GpxPhoenix.Repo,
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

* geo package
  * database setup
  * storing parsed gpx in db

<br />

## Quick intro to PostGIS

* Postgis functions
  * calculate track distance
  * search track within radius
  * convert geometry to geojson/topojson/kml

<br />

## Visualising tracks with interactive web map

* leaflet + openstreetmap
  * displaying track as multilinestring
  * render leafelt + track
