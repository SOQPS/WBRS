/// Preserves the existing questionnaire's tie-breaking order.
/// Scores are brown, red, blue, white. Changing the methodology needs approval.
String classifyTemperament(List<int> scores) {
  if (scores.length != 4 ||
      scores.any((score) => score < 0 || score > 20) ||
      scores.fold<int>(0, (sum, score) => sum + score) < 20) {
    throw ArgumentError('Select at least 20 of the 80 statements');
  }
  final brownGroup = scores[0],
      redGroup = scores[1],
      blueGroup = scores[2],
      whiteGroup = scores[3];
  int max = 0, max2 = 0;
  String group = '';
  if (brownGroup > max) {
    max = brownGroup;
  }

  if (redGroup > max) {
    max = redGroup;
  }

  if (whiteGroup > max) {
    max = whiteGroup;
  }

  if (blueGroup > max) {
    max = blueGroup;
  }

  if (brownGroup > max2 && brownGroup != max) {
    max2 = brownGroup;
  }

  if (redGroup > max2 && redGroup != max) {
    max2 = redGroup;
  }

  if (whiteGroup > max2 && whiteGroup != max) {
    max2 = whiteGroup;
  }

  if (blueGroup > max2 && blueGroup != max) {
    max2 = blueGroup;
  }

  if (max == brownGroup) {
    if (max2 > 0) {
      if (max2 == redGroup) {
        group = 'коричнево-красная';
      }
      if (max2 == blueGroup) {
        group = 'коричнево-синяя';
      }
      if (max2 == whiteGroup) {
        group = 'коричнево-белая';
      }
    } else {
      group = 'коричневая';
    }
  }

  if (max == redGroup) {
    if (max2 > 0) {
      if (max2 == brownGroup) {
        group = 'красно-коричневая';
      }
      if (max2 == blueGroup) {
        group = 'красно-синяя';
      }
      if (max2 == whiteGroup) {
        group = 'красно-белая';
      }
    } else {
      group = 'красная';
    }
  }

  if (max == blueGroup) {
    if (max2 > 0) {
      if (max2 == redGroup) {
        group = 'сине-красная';
      }
      if (max2 == brownGroup) {
        group = 'сине-коричневая';
      }
      if (max2 == whiteGroup) {
        group = 'сине-белая';
      }
    } else {
      group = 'синяя';
    }
  }

  if (max == whiteGroup) {
    if (max2 > 0) {
      if (max2 == redGroup) {
        group = 'бело-красная';
      }
      if (max2 == blueGroup) {
        group = 'бело-синяя';
      }
      if (max2 == brownGroup) {
        group = 'бело-коричневая';
      }
    } else {
      group = 'белая';
    }
  }
  return group;
}
