/// Curated picsum.photos IDs hand-picked to look like print-worthy photos
/// (family / lifestyle / travel / portraits). Stable IDs — same image every
/// time. Used across product cards and pack pills so customers see what a real
/// print at that size will look like.
class SampleImages {
  // Family / candid / lifestyle
  static const family = <int>[
    1027, // woman portrait
    1062, // group friends
    1067, // mother-daughter
    1074, // couple bw
    177, // kids playing
    342, // woman smiling
    415, // group selfie
    718, // baby
  ];

  // Travel / scenery
  static const travel = <int>[
    1015, // mountain stream
    1018, // forest
    1019, // city skyline
    1043, // boat in fog
    152, // ocean rocks
    164, // beach
    225, // mountains lake
    274, // coast
  ];

  // Pets
  static const pets = <int>[
    1025, // puppy
    169, // dog face
    237, // labrador
    582, // cat
  ];

  // Portraits
  static const portraits = <int>[
    64, // child on shoulders
    65, // smiling child
    91, // bride
    177, // family kids
    836, // young woman
    1011, // beach woman
    349, // smiling woman
  ];

  /// All curated IDs combined (de-duped) for round-robin assignment.
  static const all = <int>[
    1027, 1062, 1067, 1074, 342, 415, 718,
    1015, 1018, 1019, 1043, 152, 164, 225, 274,
    1025, 169, 237, 582,
    64, 65, 91, 836, 1011, 349,
    177,
  ];

  /// Pick the i-th image in [list] (or in [all]) using modulo, so the same
  /// index always returns the same photo.
  static int idAt(int index, {List<int>? from}) {
    final src = from ?? all;
    return src[index.abs() % src.length];
  }

  /// Build a Picsum URL for a photo at the requested dimensions.
  /// Pass higher dims for sharper rendering on Retina displays.
  /// (Kept for any legacy reference — prefer [assetPath] so the image
  /// loads instantly from the bundled APK, not the network.)
  static String url(int id, {int width = 600, int height = 600}) =>
      'https://picsum.photos/id/$id/$width/$height';

  /// Bundled-asset path for a sample photo. The image is shipped inside
  /// the APK so it renders instantly with no network request.
  /// Files live in `assets/sample_photos/<id>.jpg` (400×400 each).
  static String assetPath(int id) => 'assets/sample_photos/$id.jpg';
}
