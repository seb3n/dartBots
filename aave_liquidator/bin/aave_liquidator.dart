import 'dart:convert';
import 'dart:io';

import 'package:aave_liquidator/config.dart';
import 'package:aave_liquidator/contract_interface/aave_lending_pool_event_manager.dart';
import 'package:aave_liquidator/contract_interface/aave_reserve_manager.dart';
import 'package:aave_liquidator/contract_interface/aave_user_manager.dart';
import 'package:aave_liquidator/contract_interface/chain_link_interface.dart';
import 'package:aave_liquidator/helper/contract_helpers/aave_contracts.dart';
import 'package:aave_liquidator/helper/contract_helpers/chainlink_contracts.dart';
import 'package:aave_liquidator/logger.dart';
import 'package:aave_liquidator/model/aave_reserve_model.dart';
import 'package:aave_liquidator/services/mongod_service.dart';
import 'package:aave_liquidator/services/web3_service.dart';
import 'package:dotenv/dotenv.dart';
import 'package:logger/logger.dart';
import 'package:web3dart/web3dart.dart';

final log = getLogger('main');
void main() async {
  /// set debug level
  Logger.level = Level.info;
  log.v('Success, We\'re In!');

  /// Load env
  load();

  /// prompt user to select network.
  print(
      'Select Network:\n 0:kovan testnet\n 1:Mainnet\n 2:Polygon\n 3:Avalanche');

  int _requireNetworkSelection() {
    String? _userInput = stdin.readLineSync(encoding: utf8);

    if (_userInput != null && _userInput.isNotEmpty) {
      return int.parse(_userInput.trim());
    } else {
      print('invalid answer. Please review documentation.');

      exit(1);
    }
  }

  int _userSelection = _requireNetworkSelection();
  var _selectedNetwork = DeployedNetwork.values[_userSelection];

  print('running app using $_selectedNetwork');

  /// setup configs
  final Config _config = Config(network: _selectedNetwork);

  /// Connect to db.
  final MongodService _mongodService = MongodService(_config);
  await _mongodService.isReady;

  /// Connect to blockchain network via infura
  final Web3Service _web3 = Web3Service(_config, _mongodService);
  await _web3.isReady;

  /// Setup aave contracts
  final AaveContracts _aaveContracts = AaveContracts(_web3, _config);

  /// setup chainlink contracts
  final ChainlinkContracts _chainlinkContracts =
      ChainlinkContracts(_web3, _config);

  /// wait for chainlink contracts to be ready.
  await _chainlinkContracts.isReady;

  /// setup oracle.
  final ChainLinkPriceOracle _oracle = ChainLinkPriceOracle(
    chainlinkContracts: _chainlinkContracts,
    config: _config,
    mongod: _mongodService,
  );

  final AaveReserveManager _reserveManager = AaveReserveManager(
    config: _config,
    mongod: _mongodService,
    aaveContracts: _aaveContracts,
  );

  final AaveUserManager _userManager = AaveUserManager(
    config: _config,
    mongod: _mongodService,
    aaveContracts: _aaveContracts,
  );

  final AaveLendingPoolEventManager _lendingPoolEventManager =
      AaveLendingPoolEventManager(
    // config: _config,
    web3: _web3,
    aaveContracts: _aaveContracts,
  );

  /// Poll Aave reserves
  ///
  /// This is a scheduled task to update reserve data periodically
  /// TODO: create 24hr cron repeat interval.

  _pollReserveData() async {
    //TODO: move this to own poller file
    log.i('_pollReserveData');
    try {
      /// get reserve data from db.
      final List<AaveReserveData> reserveDataList =
          await _mongodService.getReservesFromDb();
      log.v('reserve list in db: $reserveDataList');

      /// get list of assets from aave.
      final List<EthereumAddress> _assetsList =
          await _reserveManager.getAaveReserveList();
      log.v('assets list: $_assetsList');

      /// get aave reserve assets symbol
      final List _assetSymbolList = await _reserveManager.getTokenSymbol();
      log.v('symbol list: $_assetSymbolList');

      /// get price from aave
      final List<BigInt> _assetPriceList =
          await _reserveManager.getAllReserveAssetPrice(_assetsList);
      log.v('asset price list: $_assetPriceList');

      /// get asset config from aave
      final List<AaveReserveConfigData> _assetConfigList =
          await _reserveManager.getAllReserveAssetConfigData(_assetsList);
      log.v('asset config list: $_assetConfigList');

      /// get asset price from chainlink
      final List<BigInt> _oracleAssetPriceList =
          await _oracle.getAllAssetsPrice(_assetsList);
      log.v('oracle pricelist: $_oracleAssetPriceList');

      /// update [reserveData] with new data
      for (int i = 0; i < _assetsList.length; i++) {
        int index = reserveDataList.indexWhere(
            (element) => element.assetAddress == _assetsList[i].toString());

        List tokenData = _assetSymbolList
            .firstWhere((element) => element[1] == _assetsList[i]);

        if (index == -1) {
          reserveDataList.add(AaveReserveData(
            assetSymbol: tokenData[0],
            assetAddress: _assetsList[i].toString(),
            assetConfig: _assetConfigList[i],
            aaveAssetPrice: _assetPriceList[i],
            assetPrice: _oracleAssetPriceList[i] == BigInt.from(-1)
                ? _assetPriceList[i]
                : _oracleAssetPriceList[i],
          ));
        } else {
          reserveDataList[index] = AaveReserveData(
            assetSymbol: tokenData[0],
            assetAddress: _assetsList[i].toString(),
            assetConfig: _assetConfigList[i],
            aaveAssetPrice: _assetPriceList[i],
            assetPrice: _oracleAssetPriceList[i] == BigInt.from(-1)
                ? _assetPriceList[i]
                : _oracleAssetPriceList[i],
          );
        }
      }

      /// update db with new reserve data.
      final reset = await _mongodService.resetReserveData(reserveDataList);
      log.v('done updating db with reserve: $reset');
    } catch (e) {
      log.e('error polling: $e');
    }
  }

  await _pollReserveData();

  /// Poll Aave for new users
  ///
  /// Update list of users in db.
  /// TODO: create 24hr cron repeat interval.
  _pollNewUsers() async {
    log.i('_pollNewUsers');
    try {
      /// get current block
      final _currentBlock = await _web3.getCurrentBlock();

      ///TODO: get borrow events since last know block in increments of 1000
      ///
      final _fromBlock = _currentBlock - 1000;
      final _borrowEvents = await _lendingPoolEventManager.queryBorrowEvent(
          fromBlock: _fromBlock);
      log.d('_borrowEvents found :${_borrowEvents.length}');
      final _userList = _lendingPoolEventManager
          .extractUserAddressFromBorrowEvent(_borrowEvents);

      await _userManager.getUserAccountData(userList: _userList);
    } catch (e) {
      log.e('error polling new users: $e');
    }
  }

  await _pollNewUsers();

  // every 30 min,
  // get assets price

  /// For every asset available on aave.
  /// Listen for price changes.
  ///
  _oracle.priceListener();

  // var newData = await _oracle.getTokenUser(
  //   tokenAddress: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
  //   tokenPrice: BigInt.parse('9047136687690356000'),
  // );
  // List liquidatable = newData
  //     .where((user) => BigInt.parse(user.genHf) < BigInt.from(10000))
  //     .toList();

  // log.w(liquidatable);

  /// TODO: call samrt contract to liquidate.

  /// Terminate all conections
  _web3.dispose();
  _mongodService.closeDb();
}
