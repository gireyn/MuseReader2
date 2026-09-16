import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/services/score_parser.dart';

void main() {
  const source = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <tempolist><tempo tick="0">2</tempo><tempo tick="1920">1</tempo></tempolist>
  <Part><Staff /></Part>
  <Staff id="1">
    <Measure number="1">
      <Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord>
      <Chord><durationType>half</durationType><Note><pitch>64</pitch></Note></Chord>
    </Measure>
  </Staff>
</museScore>
''';

  test('parses MSCX note events and MuseScore tempo units', () {
    final document = ScoreParser().parseBytes(
      utf8.encode(source),
      '/tmp/example.mscx',
    );

    expect(document.division, 480);
    expect(document.events, hasLength(2));
    expect(document.events.first.startTick, 0);
    expect(document.events.first.endTick, 480);
    expect(document.events.first.noteheadFilled, isTrue);
    expect(document.events[1].startTick, 480);
    expect(document.events[1].noteheadFilled, isFalse);
    final halfNoteGlyph = document.pages
        .expand((page) => page.glyphs)
        .firstWhere((glyph) => glyph.eventIndex == 1);
    expect(halfNoteGlyph.filled, isFalse);
    final measureNumbers = document.pages
        .expand((page) => page.glyphs)
        .where((glyph) => glyph.kind == GlyphKind.measureNumber)
        .toList();
    expect(measureNumbers, hasLength(1));
    expect(measureNumbers.single.text, '1');
    expect(document.tempoMap.bpmAt(0), 120);
    expect(document.tempoMap.tickToUs(480), 500000);
    expect(document.tempoMap.tickToUs(1920), 2000000);
    expect(document.tempoMap.tickToUs(2400), 3000000);
  });

  test(
    'honours numeric MuseScore notehead overrides in the fallback parser',
    () {
      const numericHeadType = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Part><Staff /></Part>
  <Staff id="1">
    <Measure number="1">
      <Chord>
        <durationType>quarter</durationType>
        <Note><headType>1</headType><pitch>60</pitch></Note>
      </Chord>
    </Measure>
  </Staff>
</museScore>
''';

      final document = ScoreParser().parseBytes(
        utf8.encode(numericHeadType),
        '/tmp/numeric-head-type.mscx',
      );

      expect(document.events.single.noteheadFilled, isFalse);
      expect(
        document.pages
            .expand((page) => page.glyphs)
            .singleWhere((glyph) => glyph.eventIndex == 0)
            .filled,
        isFalse,
      );
    },
  );

  test('uses a deterministic page and playback mapping', () {
    final document = ScoreParser().parseBytes(
      utf8.encode(source),
      '/tmp/example.mscx',
    );

    expect(document.pages, isNotEmpty);
    expect(document.events.first.pageIndex, 0);
    expect(document.pageForTick(0), 0);
    expect(document.tempoMap.usToTick(500000), 480);
    expect(document.tempoMap.usToTick(2500000), 2160);
    expect(document.cursorSegments, isNotEmpty);
    final firstCursor = document.cursorSegments.first;
    final midpointTick =
        firstCursor.startTick +
        (firstCursor.endTick - firstCursor.startTick) ~/ 2;
    final midpoint = document.cursorForTick(midpointTick);
    expect(midpoint, isNotNull);
    expect(midpoint!.pageIndex, firstCursor.pageIndex);
    expect(midpoint.rect.top, firstCursor.rect.top);
    expect(midpoint.rect.height, firstCursor.rect.height);
    expect(midpoint.rect.left, greaterThanOrEqualTo(firstCursor.rect.left));
  });

  test('maps each part to its MuseScore instrument program and bank', () {
    const multiInstrument = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Score>
    <Division>480</Division>
    <Part>
      <Staff id="1" />
      <Instrument>
        <Channel>
          <controller ctrl="0" value="0" />
          <controller ctrl="32" value="0" />
          <program value="0" />
        </Channel>
      </Instrument>
    </Part>
    <Part>
      <Staff id="2" />
      <Instrument>
        <Channel>
          <controller ctrl="0" value="1" />
          <controller ctrl="32" value="2" />
          <program value="73" />
        </Channel>
      </Instrument>
    </Part>
    <!-- Deliberately reverse score-staff order; ids must win over position. -->
    <Staff id="2">
      <Measure number="1">
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch></Note></Chord>
      </Measure>
    </Staff>
    <Staff id="1">
      <Measure number="1">
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord>
      </Measure>
    </Staff>
  </Score>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(multiInstrument),
      '/tmp/multi-instrument.mscx',
    );

    expect(document.events, hasLength(2));
    final piano = document.events.firstWhere((event) => event.pitch == 60);
    final flute = document.events.firstWhere((event) => event.pitch == 62);
    expect(piano.channel, 0);
    expect(piano.program, 0);
    expect(piano.bank, 0);
    expect(flute.channel, 1);
    expect(flute.program, 73);
    expect(flute.bank, 130);
    expect(document.nativeEvents.last['program'], 73);
    expect(document.nativeEvents.last['bank'], 130);
  });

  test('reads an MSCZ rootfile and fractional measure durations', () {
    final score = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Staff id="1">
    <Measure number="1">
      <voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice>
    </Measure>
    <Measure number="2">
      <voice><Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord></voice>
    </Measure>
  </Staff>
</museScore>
''';
    final container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container><rootfiles><rootfile full-path="score.mscx" /></rootfiles></container>
''';
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'META-INF/container.xml',
          container.length,
          utf8.encode(container),
        ),
      )
      ..addFile(ArchiveFile('score.mscx', score.length, utf8.encode(score)));
    final bytes = ZipEncoder().encode(archive)!;

    final document = ScoreParser().parseBytes(bytes, '/tmp/example.mscz');

    expect(document.format, ScoreFormat.mscz);
    expect(document.measures.first.endTick, 1920);
    expect(document.events.single.startTick, 1920);
    expect(document.events.single.endTick, 2400);
  });

  test('honors MuseScore irregular measure length attributes', () {
    const pickup = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Staff id="1">
    <Measure number="1" len="1/4">
      <Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord>
    </Measure>
    <Measure number="2">
      <Chord><durationType>quarter</durationType><Note><pitch>62</pitch></Note></Chord>
    </Measure>
  </Staff>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(pickup),
      '/tmp/pickup.mscx',
    );

    expect(document.measures.first.endTick, 480);
    expect(document.measures[1].startTick, 480);
    expect(document.events[1].startTick, 480);
  });

  test('tracks time signatures and in-voice tempo locations', () {
    const tempoFlow = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Staff id="1">
    <Measure number="1">
      <voice>
        <TimeSig><sigN>3</sigN><sigD>4</sigD></TimeSig>
        <Tempo><tempo>2</tempo></Tempo>
        <Rest><durationType>measure</durationType></Rest>
        <location><fractions>-1/2</fractions></location>
        <Tempo><tempo>1</tempo></Tempo>
      </voice>
    </Measure>
    <Measure number="2">
      <voice>
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch></Note></Chord>
      </voice>
    </Measure>
  </Staff>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(tempoFlow),
      '/tmp/tempo-flow.mscx',
    );

    expect(document.measures.first.endTick, 1440);
    expect(document.measures[1].startTick, 1440);
    expect(document.events.single.startTick, 1440);
    expect(document.tempoMap.bpmAt(0), 120);
    expect(document.tempoMap.bpmAt(480), 60);
    expect(document.tempoMap.tickToUs(960), 1500000);
  });

  test('uses styled score text when metadata tags are empty', () {
    const styledTitle = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <metaTag name="workTitle"></metaTag>
  <metaTag name="composer"></metaTag>
  <Staff id="1">
    <VBox>
      <Text><style>Title</style><text>Amazing Grace</text></Text>
      <Text><style>Composer</style><text>Traditional</text></Text>
    </VBox>
    <Measure><Rest><duration>4/4</duration></Rest></Measure>
  </Staff>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(styledTitle),
      '/tmp/untitled.mscx',
    );

    expect(document.title, 'Amazing Grace');
    expect(document.composer, 'Traditional');
  });

  test('preserves MuseScore per-note tuning in cents', () {
    const microtonal = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Staff id="1">
    <Measure number="1">
      <Chord><durationType>quarter</durationType>
        <Note><pitch>60</pitch><tuning>33.333333</tuning></Note>
        <Note><pitch>60</pitch><tuning>-17.5</tuning></Note>
      </Chord>
    </Measure>
  </Staff>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(microtonal),
      '/tmp/microtonal.mscx',
    );

    expect(document.events, hasLength(2));
    expect(document.events[0].tuning, closeTo(33.333333, 0.000001));
    expect(document.events[1].tuning, closeTo(-17.5, 0.000001));
    expect(document.nativeEvents[0]['tuning'], closeTo(33.333333, 0.000001));
    expect(document.nativeEvents[1]['tuning'], closeTo(-17.5, 0.000001));
  });

  test('retains persisted user play-event pitch offsets with tuning', () {
    const ornament = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <Staff id="1">
    <Measure number="1">
      <Chord><durationType>quarter</durationType>
        <Note><pitch>60</pitch><tuning>25</tuning>
          <Events><Event><pitch>1</pitch><ontime>250</ontime><len>500</len></Event></Events>
        </Note>
      </Chord>
    </Measure>
  </Staff>
</museScore>
''';

    final document = ScoreParser().parseBytes(
      utf8.encode(ornament),
      '/tmp/ornament.mscx',
    );

    expect(document.events, hasLength(1));
    expect(document.events.single.pitch, 61);
    expect(document.events.single.tuning, 25);
    expect(document.events.single.startTick, 120);
    expect(document.events.single.endTick, 360);
    expect(document.events.single.sourceTick, 0);
    expect(document.events.single.resolvedClickStartUs(document.tempoMap), 0);
  });
}
