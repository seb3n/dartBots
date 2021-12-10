import 'dart:typed_data';

import 'package:aave_liquidator/abi/liquidator/liquidator.g.dart';
import 'package:aave_liquidator/helper/contract_helpers/aave_contracts.dart';
import 'package:aave_liquidator/logger.dart';
import 'package:aave_liquidator/services/web3_service.dart';
// import 'package:flutter_web3/flutter_web3.dart' as ethers;
import 'package:web3dart/web3dart.dart';

final log = getLogger('LiquidatorContract');

class LiquidatorContract {
  late Web3Service _web3service;
  late AaveContracts _aaveContracts;
  LiquidatorContract({
    required Web3Service web3,
    required AaveContracts aaveContracts,
  }) {
    _web3service = web3;
    _aaveContracts = aaveContracts;
    _setupContract();
  }
  late Liquidator liquidator;

  _setupContract() {
    liquidator = Liquidator(
        address: EthereumAddress.fromHex(
            '0x0e801d84fa97b50751dbf25036d067dcf18858bf'),
        client: _web3service.web3Client,
        chainId: _web3service.chainId);
  }

  liquidateAaveUser({
    required String collateralAsset,
    required String debtAsset,
    required String user,
    required BigInt debtToCover,
    required bool useEthPath,
  }) async {
    log.i('liquidateAaveUser | ');
    try {
      // encode parameters given to liquidator executeOperation function
      final parametres =
          _aaveContracts.contractLiquidationCallFunction.encodeCall([
        EthereumAddress.fromHex(collateralAsset),
        EthereumAddress.fromHex(debtAsset),
        EthereumAddress.fromHex(user),
        debtToCover,
        useEthPath
      ]);
      // log.d('parametres: $parametres');
// convert [Uint8List] to [List<int>] and remove the first 4 index.
      final List<int> maListe = List.from(parametres);
      maListe.removeRange(0, 4);

      // log.d('parametresMOD: $maListe');
// re-convert into a [Uint8List].
      final Uint8List newParams = Uint8List.fromList(maListe);
      final method = liquidator.self.function('requestFlashLoan');

      final gas = await _web3service.web3Client.estimateGas(
          sender: _web3service.credentials.address,
          to: liquidator.self.address,
          data: method.encodeCall([
            [EthereumAddress.fromHex(debtAsset)],
            [debtToCover],
            [BigInt.zero],
            newParams,
          ]));
      log.wtf('gas: $gas');
      final EtherAmount gasPrice = await _web3service.web3Client.getGasPrice();
      log.d('gasPrice: ${gasPrice.getValueInUnitBI(EtherUnit.gwei)}');

      final newTx = Transaction(
        // contract: liquidator.self,
        // function: method,
        // parameters: [
        //   [EthereumAddress.fromHex(debtAsset)],
        //   [debtToCover],
        //   [BigInt.zero],
        //   newParams,
        // ],
        maxGas: gas.toInt() + 500,
      );

      /// make sure gas fees are paid.
      final transactionHash = await liquidator.requestFlashLoan(
        [EthereumAddress.fromHex(debtAsset)],
        [debtToCover],
        [BigInt.zero],
        newParams,
        credentials: _web3service.credentials,
        transaction: newTx,
      );

      final TransactionReceipt? receipt =
          await _web3service.web3Client.getTransactionReceipt(transactionHash);
      log.wtf(receipt);
    } catch (e) {
      log.e('error liquidating user: $e');
    }
  }
}