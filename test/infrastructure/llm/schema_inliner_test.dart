import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/infrastructure/llm/schema_inliner.dart';

/// `screen_shot`'s inputSchema exactly as GhostDesk (rmcp + schemars)
/// publishes it: an optional nested object behind `anyOf` + `$ref`, and an
/// enum behind a `$ref` with a sibling `default`.
const _screenShot = <String, dynamic>{
  r'$defs': {
    'ImageFormatDto': {
      'enum': ['webp', 'png'],
      'type': 'string',
    },
    'RegionDto': {
      'additionalProperties': false,
      'properties': {
        'x': {'type': 'integer'},
        'y': {'type': 'integer'},
        'width': {'type': 'integer'},
        'height': {'type': 'integer'},
      },
      'required': ['x', 'y', 'width', 'height'],
      'type': 'object',
    },
  },
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'additionalProperties': false,
  'properties': {
    'format': {r'$ref': r'#/$defs/ImageFormatDto', 'default': 'webp'},
    'region': {
      'anyOf': [
        {r'$ref': r'#/$defs/RegionDto'},
        {'type': 'null'},
      ],
      'default': null,
    },
    'stabilize': {'default': true, 'type': 'boolean'},
  },
  'type': 'object',
};

void main() {
  group('inlineLocalRefs', () {
    test('a schema without definitions is returned as is', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
      };
      expect(identical(inlineLocalRefs(schema), schema), isTrue);
    });

    test('resolves every local ref and drops the definitions block', () {
      expect(inlineLocalRefs(_screenShot), {
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'additionalProperties': false,
        'properties': {
          'format': {
            'enum': ['webp', 'png'],
            'type': 'string',
            'default': 'webp',
          },
          'region': {
            'anyOf': [
              {
                'additionalProperties': false,
                'properties': {
                  'x': {'type': 'integer'},
                  'y': {'type': 'integer'},
                  'width': {'type': 'integer'},
                  'height': {'type': 'integer'},
                },
                'required': ['x', 'y', 'width', 'height'],
                'type': 'object',
              },
              {'type': 'null'},
            ],
            'default': null,
          },
          'stabilize': {'default': true, 'type': 'boolean'},
        },
        'type': 'object',
      });
    });

    test('keywords beside a ref are kept and win over the definition', () {
      final out = inlineLocalRefs({
        r'$defs': {
          'Named': {'type': 'string', 'description': 'from the definition'},
        },
        'type': 'object',
        'properties': {
          'name': {
            r'$ref': r'#/$defs/Named',
            'description': 'from the site',
            'default': 'anon',
          },
        },
      });
      expect(out, {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'from the site',
            'default': 'anon',
          },
        },
      });
    });

    test('follows refs nested inside a definition', () {
      final out = inlineLocalRefs({
        r'$defs': {
          'Point': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
            },
          },
          'Line': {
            'type': 'object',
            'properties': {
              'from': {r'$ref': r'#/$defs/Point'},
              'to': {r'$ref': r'#/$defs/Point'},
            },
          },
        },
        'type': 'object',
        'properties': {
          'line': {r'$ref': r'#/$defs/Line'},
        },
      });
      const point = {
        'type': 'object',
        'properties': {
          'x': {'type': 'integer'},
        },
      };
      expect(out, {
        'type': 'object',
        'properties': {
          'line': {
            'type': 'object',
            'properties': {'from': point, 'to': point},
          },
        },
      });
    });

    test('reads draft-07 `definitions` as well', () {
      final out = inlineLocalRefs({
        'definitions': {
          'Id': {'type': 'string'},
        },
        'type': 'object',
        'properties': {
          'id': {r'$ref': '#/definitions/Id'},
        },
      });
      expect(out, {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
      });
    });

    test('leaves a recursive ref in place and keeps its definition', () {
      final out = inlineLocalRefs({
        r'$defs': {
          'Node': {
            'type': 'object',
            'properties': {
              'children': {
                'type': 'array',
                'items': {r'$ref': r'#/$defs/Node'},
              },
            },
          },
        },
        'type': 'object',
        'properties': {
          'root': {r'$ref': r'#/$defs/Node'},
        },
      });
      // One level is unrolled; the ref below it still points into `$defs`.
      const node = {
        'type': 'object',
        'properties': {
          'children': {
            'type': 'array',
            'items': {r'$ref': r'#/$defs/Node'},
          },
        },
      };
      expect(out, {
        r'$defs': {'Node': node},
        'type': 'object',
        'properties': {'root': node},
      });
    });

    test('leaves an unknown or external ref untouched', () {
      final out = inlineLocalRefs({
        r'$defs': {
          'Known': {'type': 'string'},
        },
        'type': 'object',
        'properties': {
          'a': {r'$ref': r'#/$defs/Missing'},
          'b': {r'$ref': 'https://example.com/schema.json'},
          'c': {r'$ref': r'#/$defs/Known'},
        },
      });
      expect(out, {
        'type': 'object',
        'properties': {
          'a': {r'$ref': r'#/$defs/Missing'},
          'b': {r'$ref': 'https://example.com/schema.json'},
          'c': {'type': 'string'},
        },
      });
    });
  });
}
