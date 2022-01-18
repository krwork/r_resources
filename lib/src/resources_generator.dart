import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import 'class_gen/image_asset_class_generator.dart';
import 'class_gen/string_class_generator.dart';
import 'class_gen/svg_asset_class_generator.dart';
import 'utils.dart';

const _defaultGeneratedClassPath = 'lib';
const _defaultSupportedLocales = ['en'];
const _defaultFallbackLocale = 'en';
const _defaultSourceFilesDirName = 'lib/';
const _optionsFileName = 'r_options.yaml';
const _pubspecFileName = 'pubspec.yaml';

/// header for generated r.dart file
@visibleForTesting
const generatedFileHeader =
    '/// THIS FILE IS GENERATED BY r_resources. DO NOT MODIFY MANUALLY.';

/// Specified line with lint ignores which will be added to top of r.dart file
///
/// Generated code might violate some lint rules,
/// so we need to ignore them to keep consumer's project to pass analyze steps
@visibleForTesting
const ignoreCommentForLinter = '// ignore_for_file: '
    'avoid_classes_with_only_static_members,'
    'always_specify_types,'
    'lines_longer_than_80_chars,'
    'non_constant_identifier_names,'
    'prefer_double_quotes,'
    'unnecessary_raw_strings,'
    'use_raw_strings';

class _GeneratorOptions {
  const _GeneratorOptions._({
    required this.path,
    required this.supportedLocales,
    required this.fallbackLocale,
    required this.isStringsGenEnabled,
  });

  factory _GeneratorOptions() => const _GeneratorOptions._(
        path: _defaultGeneratedClassPath,
        supportedLocales: _defaultSupportedLocales,
        fallbackLocale: _defaultFallbackLocale,
        isStringsGenEnabled: false,
      );

  factory _GeneratorOptions.fromYamlMap(YamlMap yamlMap) {
    final path = yamlMap['path'] as String?;
    final isStringsGenEnabled = yamlMap['generate_strings'] as bool?;
    final supportedLocalesYamlList = yamlMap['supported_locales'] as YamlList?;
    final supportedLocales = supportedLocalesYamlList == null
        ? null
        : List<String>.from(supportedLocalesYamlList);
    final fallbackLocale = yamlMap['fallback_locale'] as String?;
    return _GeneratorOptions._(
      path: path ?? _defaultGeneratedClassPath,
      supportedLocales: supportedLocales ?? _defaultSupportedLocales,
      fallbackLocale: fallbackLocale ?? _defaultFallbackLocale,
      isStringsGenEnabled: isStringsGenEnabled ?? false,
    );
  }

  final String path;
  final List<String> supportedLocales;
  final String fallbackLocale;
  final bool isStringsGenEnabled;

  bool get isPathCorrect =>
      path == _defaultGeneratedClassPath ||
      path.startsWith(_defaultSourceFilesDirName);
}

/// Main builder class for r_resources
class ResourcesBuilder implements Builder {
  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final pubSpecYamlMap = await _createPubSpecYampMap(buildStep);
    if (pubSpecYamlMap?.isEmpty ?? true) return;

    final options = _generatorOptions;
    if (!options.isPathCorrect) {
      log.severe(
        'path from $_optionsFileName should start with "lib/"',
      );
      return;
    }

    final rClass = await _generateRFileContent(
      buildStep,
      pubSpecYamlMap!,
      options,
    );
    if (rClass.isEmpty) return;

    final dir = options.path.startsWith('lib') ? options.path : 'lib';
    final output = AssetId(
      buildStep.inputId.package,
      path.join(dir, 'r.dart'),
    );
    return buildStep.writeAsString(output, rClass);
  }

  @override
  Map<String, List<String>> get buildExtensions {
    final options = _generatorOptions;
    var extensions = 'r.dart';
    if (options.path != _defaultGeneratedClassPath && options.isPathCorrect) {
      extensions =
          '${options.path.replaceFirst(_defaultSourceFilesDirName, '')}'
          '/$extensions';
    }
    return {
      r'$lib$': [
        extensions,
      ]
    };
  }

  _GeneratorOptions get _generatorOptions {
    final optionsFile = File(_optionsFileName);

    if (optionsFile.existsSync()) {
      final optionsAsString = optionsFile.readAsStringSync();
      if (optionsAsString.isNotEmpty) {
        return _GeneratorOptions.fromYamlMap(
          loadYaml(optionsAsString) as YamlMap,
        );
      }
    }

    return _GeneratorOptions();
  }

  Future<YamlMap?> _createPubSpecYampMap(BuildStep buildStep) async {
    final pubSpecAssetId = AssetId(buildStep.inputId.package, _pubspecFileName);
    final pubSpecAsString = await buildStep.readAsString(pubSpecAssetId);
    return loadYaml(pubSpecAsString) as YamlMap?;
  }

  Future<String> _generateRFileContent(
    BuildStep buildStep,
    YamlMap pubSpecYamlMap,
    _GeneratorOptions options,
  ) async {
    final assets = await _getAssetsFromPubSpec(
      buildStep,
      pubSpecYamlMap,
    );

    final imagesClassGenerator = ImageAssetClassGenerator(assets);
    final imageResourcesClass = await imagesClassGenerator.generate();

    final svgClassGenerator = SvgAssetClassGenerator(assets);
    final svgResourcesClass = await svgClassGenerator.generate();

    late StringsClassGenerator stringsClassGenerator;
    late String stringResourcesClasses;

    if (options.isStringsGenEnabled) {
      stringsClassGenerator = StringsClassGenerator(
        localizationData: await _readLocalizationFiles(buildStep, options),
        supportedLocales: options.supportedLocales,
        fallbackLocale: options.fallbackLocale,
      );
      stringResourcesClasses = await stringsClassGenerator.generate();
    }

    final generatedFileContent = StringBuffer()
      ..writeln(generatedFileHeader)
      ..writeln()
      ..writeln(ignoreCommentForLinter)
      ..writeln();

    if (options.isStringsGenEnabled) {
      generatedFileContent.writeln('import \'package:flutter/material.dart\';');
    }

    generatedFileContent
        .writeln('import \'package:margu/config/env_config.dart\';');
    generatedFileContent
      ..writeln()
      ..writeln('class R {')
      ..writeln(
        '  static const images = ${imagesClassGenerator.className}();',
      )
      ..writeln(
        '  static const svg = ${svgClassGenerator.className}();',
      );

    if (options.isStringsGenEnabled) {
      generatedFileContent.writeln(
        '  static ${stringsClassGenerator.className} '
        'stringsOf(BuildContext context) => '
        '${stringsClassGenerator.className}.of(context);',
      );
    }

    generatedFileContent
      ..writeln('}')
      ..writeln()
      ..writeln(imageResourcesClass)
      ..writeln()
      ..writeln(svgResourcesClass);

    if (options.isStringsGenEnabled) {
      generatedFileContent
        ..writeln()
        ..writeln(stringResourcesClasses);
    }

    return generatedFileContent.toString();
  }

  Future<List<AssetId>> _getAssetsFromPubSpec(
    BuildStep buildStep,
    YamlMap pubSpecYamlMap,
  ) async {
    final globList = _getUniqueAssetsGlobsFromPubSpec(pubSpecYamlMap);
    final assetsSet = <AssetId>{};

    for (final glob in globList) {
      final assets = await buildStep.findAssets(glob).toList();
      assetsSet.addAll(
        assets.where(
          // remove invisible files: .gitignore, .DS_Store, etc.
          (it) => it.pathSegments.last.fileName.isNotEmpty,
        ),
      );
    }

    return assetsSet.toList();
  }

  Set<Glob> _getUniqueAssetsGlobsFromPubSpec(YamlMap pubSpecYamlMap) {
    final globList = <Glob>{};
    for (final asset in _getUniqueAssetsPathsFromPubSpec(pubSpecYamlMap)) {
      if (asset.endsWith('/')) {
        globList.add(Glob('$asset*'));
      } else {
        globList.add(Glob(asset));
      }
    }

    return globList;
  }

  Set<String> _getUniqueAssetsPathsFromPubSpec(YamlMap pubSpecYamlMap) {
    if (pubSpecYamlMap.containsKey('flutter')) {
      final dynamic flutterMap = pubSpecYamlMap['flutter'];
      if (flutterMap is YamlMap && flutterMap.containsKey('assets')) {
        final assetsList = flutterMap['assets'] as YamlList;
        return Set.from(assetsList);
      }
    }

    return {};
  }

  Future<Map<String, Map<String, String>>> _readLocalizationFiles(
    BuildStep buildStep,
    _GeneratorOptions options,
  ) async {
    final result = <String, Map<String, String>>{};
    for (final locale in options.supportedLocales) {
      final assetId = AssetId(
        buildStep.inputId.package,
        'assets/strings/$locale.json',
      );
      final fileContentAsString = await buildStep.readAsString(assetId);
      final Map<String, dynamic> decodedJson = jsonDecode(fileContentAsString);
      result[locale] = Map<String, String>.from(decodedJson);
    }
    return result;
  }
}
