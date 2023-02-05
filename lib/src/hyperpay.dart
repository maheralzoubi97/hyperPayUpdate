// Copyright 2022 NyarTech LLC. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file.

part of hyperpay;

/// The interface for Hyperpay SDK.
/// To use this plugin, you will need to have 2 endpoints on your server.
///
/// Please check
/// [the guide to setup your server](https://wordpresshyperpay.docs.oppwa.com/tutorials/mobile-sdk/integration/server).
///
/// Refer to [HyperPay API](https://wordpresshyperpay.docs.oppwa.com/reference/parameters)
/// for more information on Test/Live systems.
class HyperpayPlugin {
  HyperpayPlugin._(this._config);
  //static HyperpayPlugin instance = HyperpayPlugin._();

  static const MethodChannel _channel =
      const MethodChannel('plugins.nyartech.com/hyperpay');

  late HyperpayConfig _config;

  CheckoutSettings? _checkoutSettings;
  String _checkoutID = '';

  /// Read the configurations used to setup this instance of HyperPay.
  HyperpayConfig get config => _config;

  /// Setup HyperPay instance with the required stuff to make a successful
  /// payment transaction.
  ///
  /// See [HyperpayConfig], [PaymentMode]
  static Future<HyperpayPlugin> setup({required HyperpayConfig config}) async {
    await _channel.invokeMethod(
      'setup_service',
      {
        'mode': config.paymentMode.string,
      },
    );

    return HyperpayPlugin._(config);
  }

  /// Instantiate a checkout session.
  void initSession({required CheckoutSettings checkoutSetting}) async {
    // ensure anything from previous session is cleaned up.
    _clearSession();
    _checkoutSettings = checkoutSetting;
  }

  /// Used to clear any lefovers from previous session
  /// before starting a new one.
  void _clearSession() {
    if (_checkoutSettings != null) {
      _checkoutSettings?.clear();
    }
  }

  /// A call to the endpoint on your server to get a checkout ID.
  Future<String> get getCheckoutID async {
    try {
      final body = {
        'entityId': _checkoutSettings?.brand.entityID(config),
        ..._checkoutSettings?.additionalParams ?? {},
      };
      var response = await post(
        Uri.parse(
          _config.checkoutEndpoint.toString(),
        ),
        headers: _checkoutSettings?.headers,
        body: jsonEncode(body),
      );

      if (response.statusCode != 200) {
        throw HttpException(
            'This vehicle is already booked \n ${response.body}');
      }

      final Map _resBody = json.decode(response.body);

      log(_resBody['payment']['result']['code']);

      if (_resBody['payment']['result'] != null &&
          _resBody['payment']['result']['code'] != null) {
        switch (_resBody['payment']['result']['code']) {
          case '000.200.100':
            _checkoutID = _resBody['payment']['id'];
            break;
          case '200.300.404':
            throw HyperpayException(
              _resBody['payment']['result']['description'],
              _resBody['payment']['result']['code'],
              _resBody.containsKey('parameterErrors')
                  ? _resBody['payment']['result']['parameterErrors']
                      .map(
                        (param) =>
                            '(param: ${param['name']}, value: ${param['value']})',
                      )
                      .join(',')
                  : '',
            );
          default:
            throw HyperpayException(
              _resBody['description'],
              _resBody['code'],
            );
        }

        log(_checkoutID, name: "HyperpayPlugin/getCheckoutID");

        return _checkoutID;
      } else {
        throw const HyperpayException(
          'The returned result does not contain the key "result" as the first key.',
          'RESPONSE BODY NOT IDENTIFIED',
          'please structure the returned body as {result: {code: CODE, description: DESCRIPTION}, id: CHECKOUT_ID, ...}.',
        );
      }
    } catch (exception) {
      log('${exception.toString()}', name: "HyperpayPlugin/getCheckoutID");
      rethrow;
    }
  }

  /// Perform the transaction using iOS/Android HyperPay SDK.
  ///
  /// It's highly recommended to setup a listner using
  /// [HyperPay webhooks](https://wordpresshyperpay.docs.oppwa.com/tutorials/webhooks),
  /// and perform the requird action after payment (e.g. issue receipt) on your server.
  Future<PaymentStatus> pay(CardInfo card) async {
    try {
      final result = await _channel.invokeMethod(
        'start_payment_transaction',
        {
          'checkoutID': _checkoutID,
          'brand': _checkoutSettings?.brand.name.toUpperCase(),
          'card': card.toMap(),
        },
      );

      log('$result', name: "HyperpayPlugin/platformResponse");

      if (result == 'canceled') {
        // Checkout session is still going on.
        return PaymentStatus.init;
      } else if (result == 'synchronous') {
        final status = await paymentStatus(
          _checkoutID,
          headers: _checkoutSettings?.headers,
        );

        final String code = status['code'];

        if (code.paymentStatus == PaymentStatus.rejected) {
          throw HyperpayException(
              "Rejected payment.", code, status['description']);
        } else {
          log('${code.paymentStatus}', name: "HyperpayPlugin/paymentStatus");

          _clearSession();
          _checkoutID = '';

          return code.paymentStatus;
        }
      } else {
        // if success .........

        final status = await paymentStatus(
          _checkoutID,
          headers: _checkoutSettings?.headers,
        );

        final String code = status['code'];

        if (code.paymentStatus == PaymentStatus.rejected) {
          throw HyperpayException(
              "Rejected payment.", code, status['description']);
        } else {
          log('${code.paymentStatus}', name: "HyperpayPlugin/paymentStatus");

          _clearSession();
          _checkoutID = '';

          return code.paymentStatus;
        }
      }
    } catch (e) {
      log('$e', name: "HyperpayPlugin/pay");
      rethrow;
    }
  }

  /// Perform a transaction natively with Apple Pay.
  ///
  /// This method will throw a [NOT_SUPPORTED] error on any platform other than iOS.
  Future<PaymentStatus> payWithApplePay(ApplePaySettings applePay) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      throw HyperpayException(
        'Apple Pay is not supported on $defaultTargetPlatform.',
        'NOT_SUPPORTED',
      );
    }

    try {
      final result = await _channel.invokeMethod(
        'start_payment_transaction',
        {
          'checkoutID': _checkoutID,
          'brand': BrandType.applepay.name.toUpperCase(),
          ...applePay.toJson(),
        },
      );

      log('$result', name: "HyperpayPlugin/platformResponse");

      if (result == 'canceled') {
        // Checkout session is still going on.
        return PaymentStatus.init;
      }

      final status = await paymentStatus(
        _checkoutID,
        headers: _checkoutSettings?.headers,
      );

      final String code = status['code'];

      if (code.paymentStatus == PaymentStatus.rejected) {
        throw HyperpayException(
            "Rejected payment.", code, status['description']);
      } else {
        log('${code.paymentStatus}', name: "HyperpayPlugin/paymentStatus");

        _clearSession();
        _checkoutID = '';

        return code.paymentStatus;
      }
    } catch (e) {
      log('$e', name: "HyperpayPlugin/payWithApplePay");
      rethrow;
    }
  }

  /// Check for payment status using a [checkoutID].
  Future<Map<String, dynamic>> paymentStatus(String checkoutID,
      {Map<String, String>? headers}) async {
    try {
      final body = {
        'entityId': _checkoutSettings?.brand.entityID(config),
      };

      var response = await post(
        Uri.parse(
            "https://e5rnoxpn09.execute-api.eu-central-1.amazonaws.com/dev/driver/query/checkOnPaymentAndBooking/$_checkoutID"),
        headers: _checkoutSettings?.headers,
        body: jsonEncode(body),
      );

      log("status \t ${response.body}");

      Map<String, dynamic> _resBody = {};

      try {
        _resBody = json.decode(response.body);
      } catch (e) {
        _resBody['body'] = response.body;
      }

      if (_resBody['result'] != null && _resBody['result']['code'] != null) {
        log(
          '${_resBody['result']['code']}: ${_resBody['result']['description']}',
          name: "HyperpayPlugin/checkPaymentStatus",
        );

        return _resBody['result'];
      } else {
        throw HyperpayException(
          'The returned result does not contain the key "result" as the first key.',
          'RESPONSE BODY NOT IDENTIFIED',
          'please structure the returned body as {result: {code: CODE, description: DESCRIPTION}, id: CHECKOUT_ID, ...}.',
        );
      }
    } catch (exception) {
      rethrow;
    }
  }
}
