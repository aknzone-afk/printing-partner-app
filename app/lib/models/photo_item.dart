class PhotoItem {
  PhotoItem({
    required this.id,
    required this.localPath,
    this.quantity = 1,
  });

  final String id;
  final String localPath;
  int quantity;
}
