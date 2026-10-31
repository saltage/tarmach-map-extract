# Tarmach map extract

How the basemap inside Tarmach is built: the
map its monthly roundup draws journeys over. Tarmach is an iPhone app that
logs car journeys from the phone's own sensors.

The app ships two extracts in the
[PMTiles](https://github.com/protomaps/PMTiles) format, in the
[OpenMapTiles](https://openmaptiles.org) schema:

| File in the app | Built as | Covers | Zooms |
|---|---|---|---|
| `gb.pmtiles` | `gb-noplace` | Great Britain, without place names | 0–12 |
| `world.pmtiles` | `world` | The world, coastlines and major roads | 0–6 |

Their SHA-256 checksums are in [`CHECKSUMS`](CHECKSUMS), and the dates of the
data they were built from are in [`SOURCES.txt`](SOURCES.txt).

## Licence of the data

The extracts are a **Derivative Database of OpenStreetMap** and are made
available under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
© [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

ODbL section 4.6 lets a derivative database be offered as the method used to
create it. This repository is that method: the script, the profile and the
source list are what you need to rebuild the same extracts from the original
data.

The extracts also use:
- [OpenMapTiles](https://openmaptiles.org) (schema, CC-BY 4.0), via
  [planetiler](https://github.com/onthegomap/planetiler)'s OpenMapTiles profile;
- [Natural Earth](https://www.naturalearthdata.com) (public domain), for low
  zooms and the world layer's roads;
- [OSM water polygons](https://osmdata.openstreetmap.de/data/water-polygons.html)
  from openstreetmapdata.de (ODbL), for coastlines.

## What the profile changes

[`profile/TarmacExtract.java`](profile/TarmacExtract.java) subclasses
planetiler's OpenMapTiles profile. It adds:
- A-roads (`primary`) at zooms 5–6 and B-roads (`secondary`) at 5–8, below
  where OpenMapTiles starts them, so they exist at the scale of a month's
  driving;
- the numbers of numbered roads from zoom 9;
- for the world layer, Natural Earth's major roads.

The file's header has the details. Everything else is OpenMapTiles as
planetiler builds it, limited to the layers the app reads: `water`,
`waterway`, `transportation`, `transportation_name`, `place`,
`mountain_peak` and `water_name` (`gb-noplace` leaves out `place`).

## Rebuilding

Needs macOS with Homebrew, Java 21 (installed by `setup`), a 24 GB Java heap for
Great Britain (`XMX=` to change it), and about 4 GB of downloads.

```bash
./build.sh setup     # Java 21, pmtiles, planetiler 0.10.2, and the sources
./build.sh all       # london, gb, gb-noplace and world, into work/out/
./build.sh verify    # tile counts and layer checks
```

`setup --refresh` fetches fresh sources. Downloads are checked against
Geofabrik's published MD5s where they exist, and every source's SHA-256 is
recorded on first fetch, so a changed file is refused rather than reused.

Building from today's sources gives today's map, not byte-identical files:
OpenStreetMap changes daily. `SOURCES.txt` records the OpenStreetMap
replication time of the shipped build. It was written by the app
repository's copy of this script, under the name `scripts/extract-build.sh`.
