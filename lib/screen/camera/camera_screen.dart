import 'dart:async';
import 'dart:developer' as develop;
import 'dart:io';
import 'package:camera/camera.dart';
// import 'package:firebase_ml_vision/firebase_ml_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as imglib;
import 'package:poc_faceliveness_ml/screen/image_capture/image_capture_screen.dart';
import 'package:poc_faceliveness_ml/widget/ats_face_camera_widget.dart';

enum CaptureState { PREPARE, CAPTURING, WAIT }

enum FaceClassification {
  LEFT,
  RIGHT,
  TOP,
  BOTTOM,
  FRONT,
  SMILING,
  NONE;
}

class CameraScreen extends StatefulWidget {
  final Rect rectPrefer;

  const CameraScreen({
    super.key,
    required this.rectPrefer,
  });

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _controller;
  Future<void>? _initializeControllerFuture;
  late List<CameraDescription> cameras;
  bool isCaptureMode = true;
  double smileProb = 0;
  double rotX = 0;
  double rotY = 0;
  double rotZ = 0;
  FaceClassification faceClassification = FaceClassification.NONE;
  CaptureState captureState = CaptureState.WAIT;
  Timer? _timer;
  Set<FaceClassification> livenessDetectedSets = {};
  int _captureCounter = 0;
  int _captureCounterPrefer = 4;

  Map<String, Image?> images = {
    FaceClassification.FRONT.name: null,
    FaceClassification.LEFT.name: null,
    FaceClassification.RIGHT.name: null,
  };

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  String rotState = '';
  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(enableClassification: true, enableTracking: true),
  );

  bool get isValidBeforeCaptureImage => captureState == CaptureState.PREPARE;

  get currentOnlySingleFaceState => livenessDetectedSets.length == 1 ? livenessDetectedSets.first : null;

  bool get isVisibleCounterText => _captureCounter != 0 && _captureCounter != _captureCounterPrefer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      initializeCamera();
    });
  }

  Future<void> initializeCamera() async {
    // Get the list of available cameras.
    cameras = await availableCameras();

    if (cameras.isEmpty) {
      // Handle no available cameras.
    } else {
      // Use the first camera from the list.
      _controller = CameraController(
        cameras.firstWhere((element) => element.lensDirection == CameraLensDirection.front),
        ResolutionPreset.medium,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      // Initialize the camera controller.
      _initializeControllerFuture = _controller.initialize().then((_) {
        if (!mounted) {
          return;
        }
        _controller.startImageStream((CameraImage cameraImage) {
          Future.delayed(const Duration(milliseconds: 500), () {
            doStreamProcessCamera(cameraImage);
          });
        });
      });
      // if (_controller.description.lensDirection == CameraLensDirection.back) {}
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: true,
      child: Scaffold(
        appBar: AppBar(title: const Text('Face Liveness')),
        // body: AtsFaceCameraWidget(
        //   rectPrefer: Rect.fromLTRB(75, 150, 385, 460),
        // ),
      ),
    );
  }

  Future<void> processCameraImage(
    CameraImage cameraImage,
  ) async {
    develop.log('processCameraImage::');
    final inputImage = _inputImageFromCameraImage(cameraImage);

    if (inputImage == null) {
      return;
    }

    final List<Face> faces = await _faceDetector.processImage(inputImage);

    for (Face face in faces) {
      final Rect boundingBox = face.boundingBox;

      CaptureState currentCaptureState = doUpdateCaptureState(boundingBox);
      doUpdateAllRot(face);
      doUpdateClassification(face);
      doUpdateFacePropInfo(boundingBox, face);
      doUpdateLivenessDetectedSets();

      // if (currentCaptureState == CaptureState.PREPARE) {

      //   doCaptureCameraImage(imageFrame, );
      // }
      // develop.log('processCameraImage:face: $rotX $rotY $rotZ');
      // If landmark detection was enabled with FaceDetectorOptions (mouth, ears,
      // eyes, cheeks, and nose available):
      // final FaceLandmark? leftEar = face.landmarks[FaceLandmarkType.lef];
      // if (leftEar != null) {
      //   final Point<int> leftEarPos = leftEar.position;
      // }

      // // If face tracking was enabled with FaceDetectorOptions:
      // if (face.trackingId != null) {
      //   final int? id = face.trackingId;
      // }

      if (currentOnlySingleFaceState != null && isCaptureMode) {
        doStartCounterSaveImage(currentOnlySingleFaceState, cameraImage, inputImage);
      }
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    // get image rotation
    // it is used in android to convert the InputImage from Dart to Java
    // `rotation` is not used in iOS to convert the InputImage from Dart to Obj-C
    // in both platforms `rotation` and `camera.lensDirection` can be used to compensate `x` and `y` coordinates on a canvas
    final camera = cameras.firstWhere((element) => element.lensDirection == CameraLensDirection.front);
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        // front-facing
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // back-facing
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // get image format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    // validate format depending on platform
    // only supported formats:
    // * nv21 for Android
    // * bgra8888 for iOS
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) return null;

    // since format is constraint to nv21 or bgra8888, both only have one plane
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    // compose InputImage using bytes
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used only in Android
        format: format, // used only in iOS
        bytesPerRow: plane.bytesPerRow, // used only in iOS
      ),
    );
  }

  bool isFrontLivenessDetected() {
    return !isLeftLivenessDetected() &&
        !isRightLivenessDetected() &&
        !isTopLivenessDetected() &&
        !isBottomLivenessDetected();
  }

  bool isLeftLivenessDetected() {
    return rotY < -20;
  }

  bool isRightLivenessDetected() {
    return rotY > 20;
  }

  bool isTopLivenessDetected() {
    return rotX > 10;
  }

  bool isBottomLivenessDetected() {
    return rotX < -10;
  }

  bool isSmileLivenessDetected() {
    return smileProb >= 0.7;
  }

  bool isMaskDetected() {
    return false;
  }

  Color getStrokeColor() {
    if (captureState == CaptureState.PREPARE) {
      return Colors.green;
    } else if (captureState == CaptureState.CAPTURING) {
      return Colors.green;
    } else {
      return Colors.white;
    }
  }

  Future<void> onSaveImage(
      FaceClassification faceClassification, CameraImage cameraImage, InputImage inputImage) async {
    if (!isValidBeforeCaptureImage) {
      return;
    }

    if (images[faceClassification.name] != null) {
      return;
    }

    Image image = await _convertXFileToImage();

    // File file = await convertImagetoPng(cameraImage);
    // Image image = Image.file(file);

    switch (faceClassification) {
      case FaceClassification.LEFT:
        if (images[FaceClassification.LEFT.name] == null) {
          images[FaceClassification.LEFT.name] = image;
        }
        break;
      case FaceClassification.FRONT:
        if (images[FaceClassification.FRONT.name] == null) {
          images[FaceClassification.FRONT.name] = image;
        }
        break;
      case FaceClassification.RIGHT:
        if (images[FaceClassification.RIGHT.name] == null) {
          images[FaceClassification.RIGHT.name] = image;
        }
        break;
      default:
    }

    if (images[FaceClassification.LEFT.name] != null &&
        images[FaceClassification.RIGHT.name] != null &&
        images[FaceClassification.FRONT.name] != null) {
      _controller.stopImageStream();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ImageCaptureScreen(
            images: images,
          ),
        ),
      );

      images = {
        'FRONT': null,
        'LEFT': null,
        'RIGHT': null,
      };
    }
  }

  Future<Image> _convertXFileToImage() async {
    XFile xFile = await _controller.takePicture();
    Uint8List uint8list = await xFile.readAsBytes();
    Image image = Image.memory(uint8list);
    return image;
  }

  CaptureState doUpdateCaptureState(Rect boundingBox) {
    if ((widget.rectPrefer.contains(boundingBox.topLeft) && widget.rectPrefer.contains(boundingBox.bottomRight)) ||
        widget.rectPrefer.contains(boundingBox.topRight) && widget.rectPrefer.contains(boundingBox.bottomLeft)) {
      captureState = CaptureState.PREPARE;
    } else {
      captureState = CaptureState.WAIT;
    }

    return captureState;
  }

  void doUpdateAllRot(Face face) {
    rotX = face.headEulerAngleX ?? 0; // Head is tilted up and down rotX degrees
    rotY = face.headEulerAngleY ?? 0; // Head is rotated to the right rotY degrees
    rotZ = face.headEulerAngleZ ?? 0; // Head is tilted sideways rotZ degrees
  }

  void doUpdateClassification(Face face) {
    // If classification was enabled with FaceDetectorOptions:
    if (face.smilingProbability != null) {
      smileProb = face.smilingProbability ?? 0;
    }
  }

  void doUpdateFacePropInfo(Rect boundingBox, Face face) {
    rotState = '''
boundingBox: $boundingBox
X: $rotX 
Y: $rotY 
Z: $rotZ
smileProb: $smileProb''';
  }

  void doUpdateLivenessDetectedSets() {
    if (isLeftLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.LEFT);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.LEFT)) {
        livenessDetectedSets.remove(FaceClassification.LEFT);
      }
    }

    if (isRightLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.RIGHT);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.RIGHT)) {
        livenessDetectedSets.remove(FaceClassification.RIGHT);
      }
    }

    if (isTopLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.TOP);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.TOP)) {
        livenessDetectedSets.remove(FaceClassification.TOP);
      }
    }

    if (isBottomLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.BOTTOM);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.BOTTOM)) {
        livenessDetectedSets.remove(FaceClassification.BOTTOM);
      }
    }

    if (isFrontLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.FRONT);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.FRONT)) {
        livenessDetectedSets.remove(FaceClassification.FRONT);
      }
    }
    if (isSmileLivenessDetected()) {
      livenessDetectedSets.add(FaceClassification.SMILING);
    } else {
      if (livenessDetectedSets.contains(FaceClassification.SMILING)) {
        livenessDetectedSets.remove(FaceClassification.SMILING);
      }
    }

    if (isMaskDetected()) {}
  }

  void doStreamProcessCamera(CameraImage cameraImage) {
    setState(() {
      processCameraImage(cameraImage);
    });
  }

  void doStartCounterSaveImage(
      FaceClassification currentOnlySingleFaceState, CameraImage cameraImage, InputImage inputImage) async {
    if (_timer != null || images[currentOnlySingleFaceState.name] != null) {
      if (!isValidBeforeCaptureImage) {
        doStopTimer();
      }

      return;
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _captureCounter++;

      if (_captureCounter >= _captureCounterPrefer) {
        await onSaveImage(currentOnlySingleFaceState, cameraImage, inputImage);
        doStopTimer();
        setState(() {});
      }
    });
  }

  doStopTimer() {
    _captureCounter = 0;
    _timer?.cancel();
    _timer = null;
  }

  Future<File> convertImagetoPng(CameraImage cameraImage) async {
    // Create a 256x256 8-bit (default) rgb (default) image.
    final image = imglib.Image(width: cameraImage.width, height: cameraImage.height);
    // Iterate over its pixels
    for (var pixel in image) {
      // Set the pixels red value to its x position value, creating a gradient.
      pixel
        ..r = pixel.x
        // Set the pixels green value to its y position value.
        ..g = pixel.y;
    }
    // Encode the resulting image to the PNG image format.
    final png = imglib.encodePng(image);
    // Write the PNG formatted data to a file.
    return await File('image.png').writeAsBytes(png);
  }
}
