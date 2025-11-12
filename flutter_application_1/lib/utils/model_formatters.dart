String? formatModelLabel(String? canonical) {
  if (canonical == null || canonical.isEmpty) return null;
  final parts = canonical.split('_');
  final buffer = <String>[];
  for (final raw in parts) {
    final lower = raw.toLowerCase();
    buffer.add(_formatModelSegment(lower));
  }
  final label = buffer.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return label.isEmpty ? null : label;
}

String _formatModelSegment(String lower) {
  switch (lower) {
    case 'galaxy':
      return 'Galaxy';
    case 'iphone':
      return 'iPhone';
    case 'note':
      return 'Note';
    case 'z':
      return 'Z';
    case 'fold':
      return 'Fold';
    case 'flip':
      return 'Flip';
    case 'promax':
      return 'Pro Max';
    case 'pro':
      return 'Pro';
    case 'plus':
      return 'Plus';
    case 'ultra':
      return 'Ultra';
    case 'fe':
      return 'FE';
    case 'max':
      return 'Max';
    case 'mini':
      return 'Mini';
  }

  if (RegExp(r'^s\d+$').hasMatch(lower)) return lower.toUpperCase();
  if (RegExp(r'^z\d+$').hasMatch(lower)) return lower.toUpperCase();
  if (RegExp(r'^\d+$').hasMatch(lower)) return lower;

  final match = RegExp(r'^([a-z]+)(\d+)$').firstMatch(lower);
  if (match != null) {
    final prefix = _formatModelSegment(match.group(1)!);
    return '$prefix ${match.group(2)!}'.trim();
  }

  return lower.length == 1
      ? lower.toUpperCase()
      : lower[0].toUpperCase() + lower.substring(1);
}

String? formatStorageLabel(String? canonical) {
  if (canonical == null || canonical.isEmpty) return null;
  if (canonical.endsWith('tb')) {
    final value = canonical.replaceAll(RegExp(r'[^0-9]'), '');
    return value.isEmpty ? canonical.toUpperCase() : '${value}TB';
  }
  if (canonical.endsWith('g')) {
    final value = canonical.replaceAll(RegExp(r'[^0-9]'), '');
    return value.isEmpty ? canonical.toUpperCase() : '${value}GB';
  }
  return canonical.toUpperCase();
}
