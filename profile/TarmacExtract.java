// The roundup's basemap extract: planetiler's OpenMapTiles profile, plus the
// few features the Tarmac style and the roundup's cards need at zooms where
// OpenMapTiles leaves them out. Run by build.sh with Java 21's
// single-file source launcher against planetiler.jar, so there is no build
// step and no fork of planetiler-openmaptiles to keep in step.
//
// What OpenMapTiles 3.16 does by default (planetiler-openmaptiles,
// layers/Transportation.java MINZOOMS and TransportationName.java):
//   transportation       motorway z4, trunk z5-6, primary z7, secondary z9,
//                        tertiary z11, minor z12
//   transportation_name  motorway z6, trunk z8, everything else z12
//
// What this adds (each only below the zoom OpenMapTiles starts it, so nothing
// is drawn twice):
//   transportation       primary z5-6 and secondary z5-8, so A- and B-roads
//                        exist at month scale (story cards' RESULT, "The
//                        extract should carry B-roads at month scale");
//                        with --tarmac_tertiary_from=N, tertiary from zN too
//   transportation_name  numbered (ref'd) primary, secondary and tertiary
//                        roads from z9 (tertiary from where its line starts),
//                        for NEW's road shields: class and ref, no name, so
//                        a road merges into long runs (names arrive at z12)
//
// The added features carry the same attribute names OpenMapTiles uses (class,
// ref, ref_length, network, name...), so they merge in OpenMapTiles' own
// postProcess and the style needs no new source layer.

import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.Planetiler;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;
import java.nio.file.Path;
import org.openmaptiles.OpenMapTilesProfile;
import org.openmaptiles.generated.OpenMapTilesSchema;

public class TarmacExtract {

  static final class Profile extends OpenMapTilesProfile {
    private final Planetiler runner;
    private final int tertiaryFrom;
    private final boolean extraNames;
    private final boolean lowRoads;
    private final boolean neRoads;

    Profile(Planetiler runner) {
      super(runner);
      this.runner = runner;
      var args = runner.config().arguments();
      this.tertiaryFrom = args.getInteger("tarmac_tertiary_from",
        "transportation: carry tertiary roads from this zoom (OpenMapTiles: 11)", 11);
      this.extraNames = args.getBoolean("tarmac_names",
        "transportation_name: numbered A/B roads from z9 (OpenMapTiles: z12)", true);
      this.lowRoads = args.getBoolean("tarmac_low_roads",
        "transportation: primary and secondary from z5 (OpenMapTiles: z7, z9)", true);
      this.neRoads = args.getBoolean("tarmac_ne_roads",
        "transportation: Natural Earth's major roads, for the world layer built without OSM roads", false);
      registerSourceHandler(OSM_SOURCE, this::extra);
      if (neRoads) {
        registerSourceHandler(NATURAL_EARTH_SOURCE, this::naturalEarthRoads);
      }
    }

    @Override
    public String name() {
      return "Tarmac roundup basemap";
    }

    @Override
    public String description() {
      return "OpenMapTiles schema, roads and water for the Tarmac style, with A/B roads at month scale";
    }

    // The world layer is built from Natural Earth and the water polygons with no
    // planet-sized OSM file, so it has no roads of its own. Natural Earth's
    // 1:10m roads (public domain) give months abroad a skeleton of major roads
    // at country scale. They are generalised by kilometres, so they do not sit
    // on the real roads at close zooms: the app's MapKit fallback covers those.
    private void naturalEarthRoads(SourceFeature f, FeatureCollector features) {
      if (!"ne_10m_roads".equals(f.getSourceLayer()) || !f.canBeLine()) {
        return;
      }
      String type = f.getString("type");
      boolean expressway = "1".equals(String.valueOf(f.getTag("expressway")).replace(".0", ""));
      String cls;
      if ("Major Highway".equals(type) || "Beltway".equals(type)) {
        cls = expressway ? "motorway" : "trunk";
      } else if ("Secondary Highway".equals(type)) {
        cls = expressway ? "motorway" : "primary";
      } else {
        return;
      }
      int maxZoom = runner.config().maxzoom();
      Object mz = f.getTag("min_zoom");
      int minZoom = 4;
      if (mz instanceof Number n) {
        minZoom = Math.max(4, (int) Math.ceil(n.doubleValue()));
      }
      if (minZoom > maxZoom) {
        return;
      }
      features.line("transportation")
        .setBufferPixels(4)
        .setAttr("class", cls)
        .setMinPixelSize(0)
        .setSortKey(cls.equals("motorway") ? 6 : cls.equals("trunk") ? 5 : 4)
        .setMinZoom(minZoom);
    }

    private void extra(SourceFeature f, FeatureCollector features) {
      if (!f.canBeLine() || f.canBePolygon() && f.hasTag("area", "yes")) {
        return;
      }
      String highway = f.getString("highway");
      if (highway == null) {
        return;
      }
      int omtLine;   // where OpenMapTiles starts the line
      int ourLine;   // where we start it
      int rank;
      switch (highway) {
        case "primary" -> { omtLine = 7; ourLine = 5; rank = 4; }
        case "secondary" -> { omtLine = 9; ourLine = 5; rank = 3; }
        case "tertiary" -> { omtLine = 11; ourLine = Math.min(11, tertiaryFrom); rank = 2; }
        default -> { return; }
      }
      // OpenMapTiles drops tunnels from nothing, but the style hides them; a
      // tunnel added at low zoom would draw, so leave them out.
      if (f.hasTag("tunnel") && !f.hasTag("tunnel", "no")) {
        return;
      }
      int maxZoom = runner.config().maxzoom();
      if (!lowRoads) {
        ourLine = omtLine;
      }
      if (ourLine < omtLine && ourLine <= maxZoom) {
        features.line("transportation")
          .setBufferPixels(4)
          .setAttr("class", highway)
          .setMinPixelSize(0)
          .setSortKey(rank)
          .setMinZoom(ourLine)
          .setMaxZoom(Math.min(omtLine - 1, maxZoom));
      }

      String ref = f.getString("ref");
      if (extraNames && ref != null && !ref.isBlank()) {
        int from = Math.max(9, ourLine);
        if (from < 12 && from <= maxZoom) {
          features.line("transportation_name")
            .setBufferPixels(8)
            // ref only, no names: a B-road's ways carry a different street
            // name every few hundred metres, which stops them merging, and a
            // shield needs only the number. Names come in at z12 as usual.
            .setAttr("ref", ref)
            .setAttr("ref_length", ref.length())
            .setAttr("network", "road")
            .setAttr("class", highway)
            .setMinPixelSize(0)
            .setSortKey(rank)
            .setMinZoom(from)
            .setMaxZoom(Math.min(11, maxZoom));
        }
      }
    }
  }

  public static void main(String[] argv) throws Exception {
    Arguments arguments = Arguments.fromArgsOrConfigFile(argv);
    Path sources = arguments.file("download_dir", "source directory", Path.of("data/sources"));
    Planetiler.create(arguments)
      .setDefaultLanguages(OpenMapTilesSchema.LANGUAGES)
      .setProfile(Profile::new)
      .addShapefileSource("EPSG:3857", OpenMapTilesProfile.LAKE_CENTERLINE_SOURCE,
        sources.resolve("lake_centerline.shp.zip"))
      .addShapefileSource(OpenMapTilesProfile.WATER_POLYGON_SOURCE,
        sources.resolve("water-polygons-split-3857.zip"))
      .addNaturalEarthSource(OpenMapTilesProfile.NATURAL_EARTH_SOURCE,
        sources.resolve("natural_earth_vector.sqlite.zip"))
      .addOsmSource(OpenMapTilesProfile.OSM_SOURCE, sources.resolve("monaco.osm.pbf"))
      .setOutput(Path.of("data/output.pmtiles"))
      .run();
  }
}
