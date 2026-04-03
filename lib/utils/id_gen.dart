import 'package:uuid/uuid.dart';

const uuid = Uuid();

String generateId() => uuid.v4();
