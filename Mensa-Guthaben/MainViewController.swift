//
//  ViewController.swift
//  Mensa-Guthaben
//
//  Created by Georg on 11.08.19.
//  Copyright © 2019 Georg Sieber. All rights reserved.
//

import UIKit
import CoreNFC
import SQLite3
import GoogleMobileAds

class MainViewController: UIViewController, NFCTagReaderSessionDelegate {
    
    static var APP_ID  : Int    = 0x5F8415
    static var FILE_ID : UInt8  = 1
    
    var session: NFCTagReaderSession?
    var db = MensaDatabase()
    
    @IBOutlet weak var bottomStackView: UIStackView!
    var bannerView: GADBannerView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        initAds()
    }
    
    func initAds() {
        bannerView = GADBannerView(adSize: kGADAdSizeBanner)
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        bottomStackView.insertArrangedSubview(bannerView, at: 0)
        bottomStackView.addConstraints(
            [
             NSLayoutConstraint(item: bannerView!,
                              attribute: .centerX,
                              relatedBy: .equal,
                              toItem: bottomStackView,
                              attribute: .centerX,
                              multiplier: 1,
                              constant: 0)
          ])
        //bannerView.adUnitID = "ca-app-pub-3940256099942544/2934735716" // test
        bannerView.adUnitID = "ca-app-pub-9874695726033794/3374012921"
        bannerView.rootViewController = self
        bannerView.load(GADRequest())
    }
    
    @IBOutlet weak var labelCurrentBalance: UILabel!
    @IBOutlet weak var labelLastTransaction: UILabel!
    @IBOutlet weak var labelCardID: UILabel!
    @IBOutlet weak var labelDate: UILabel!
    
    @IBAction func onClick(_ sender: UIButton) {
        guard NFCTagReaderSession.readingAvailable else {
            let alertController = UIAlertController(
                title: NSLocalizedString("NFC Not Supported", comment: ""),
                message: NSLocalizedString("This device doesn't support NFC tag scanning.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alertController, animated: true, completion: nil)
            return
        }
        
        session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
        session?.alertMessage = NSLocalizedString("Please hold your Mensa card near the NFC sensor.", comment: "")
        session?.begin()
    }
    
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print(error.localizedDescription)
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        if(tags.count != 1) {
            print("MULTIPLE TAGS! ABORT.")
            return
        }
        
        if case let NFCTag.miFare(tag) = tags.first! {
            
            session.connect(to: tags.first!) { (error: Error?) in
                if(error != nil) {
                    print("CONNECTION ERROR : "+error!.localizedDescription)
                    return
                }
                
                let idData = tag.identifier
                let idInt = idData.withUnsafeBytes {
                    $0.load(as: Int.self)
                }
                
                print("CONNECTED TO CARD")
                print("CARD-TYPE:"+String(tag.mifareFamily.rawValue))
                print("CARD-ID hex:"+idData.hexEncodedString())
                DispatchQueue.main.async {
                    self.labelCardID.text = String(idInt)
                }
                
                var appIdBuff : [Int] = [];
                appIdBuff.append ((MainViewController.APP_ID & 0xFF0000) >> 16)
                appIdBuff.append ((MainViewController.APP_ID & 0xFF00) >> 8)
                appIdBuff.append  (MainViewController.APP_ID & 0xFF)
                
                // 1st command : select app
                self.send(
                    tag: tag,
                    data: Data(_: self.wrap(
                        command: 0x5a, // command : select app
                        parameter: [UInt8(appIdBuff[0]), UInt8(appIdBuff[1]), UInt8(appIdBuff[2])] // appId as byte array
                    )),
                    completion: { (data1) -> () in
                        
                        // 2nd command : read value (balance)
                        self.send(
                            tag: tag,
                            data: Data(_: self.wrap(
                                command: 0x6c, // command : read value
                                parameter: [MainViewController.FILE_ID] // file id : 1
                            )),
                            completion: { (data2) -> () in
                                
                                // parse balance response
                                var trimmedData = data2
                                trimmedData.removeLast()
                                trimmedData.removeLast()
                                trimmedData.reverse()
                                let currentBalanceRaw = self.byteArrayToInt(
                                    buf: [UInt8](trimmedData)
                                )
                                let currentBalanceValue : Double = self.intToEuro(value:currentBalanceRaw)
                                DispatchQueue.main.async {
                                    self.labelCurrentBalance.text = String(format: "%.2f €", currentBalanceValue)
                                    self.labelDate.text = self.getDateString()
                                }
                                
                                // 3rd command : read last trans
                                self.send(
                                    tag: tag,
                                    data: Data(_: self.wrap(
                                        command: 0xf5, // command : get file settings
                                        parameter: [MainViewController.FILE_ID] // file id : 1
                                    )),
                                    completion: { (data3) -> () in
                                        
                                        // parse last transaction response
                                        var lastTransactionValue : Double = 0
                                        let buf = [UInt8](data3)
                                        if(buf.count > 13) {
                                            let lastTransactionRaw = self.byteArrayToInt(
                                                buf:[ buf[13], buf[12] ]
                                            )
                                            lastTransactionValue = self.intToEuro(value:lastTransactionRaw)
                                            DispatchQueue.main.async {
                                                self.labelLastTransaction.text = String(format: "%.2f €", lastTransactionValue)
                                            }
                                        }
                                        
                                        // insert into history
                                        self.db.insertRecord(
                                            balance: currentBalanceValue,
                                            lastTransaction: lastTransactionValue,
                                            date: self.getDateString(),
                                            cardID: String(idInt)
                                        )
                                        
                                        // dismiss iOS NFC window
                                        session.invalidate()
                                        
                                    }
                                )
                                
                            }
                        )
                        
                    }
                )
                
            }
            
        } else {
            print("INVALID CARD")
        }
    }
    
    func byteArrayToInt(buf:[UInt8]) -> Int {
        var rawValue : Int = 0
        for byte in buf {
            rawValue = rawValue << 8
            rawValue = rawValue | Int(byte)
        }
        return rawValue
    }
    func intToEuro(value:Int) -> Double {
        return (Double(value)/1000).rounded(toPlaces: 2)
    }
    
    func getDateString() -> String {
        let dateFormatterGet = DateFormatter()
        dateFormatterGet.dateFormat = "dd.MM.yyyy HH:mm"
        return dateFormatterGet.string(from: Date())
    }
    
    func wrap(command: UInt8, parameter: [UInt8]?) -> [UInt8] {
        var buff : [UInt8] = []
        buff.append(0x90)
        buff.append(command)
        buff.append(0x00)
        buff.append(0x00)
        if(parameter != nil) {
            buff.append(UInt8(parameter!.count))
            for p in parameter! {
                buff.append(p)
            }
        }
        buff.append(0x00)
        return buff
    }
    func send(tag:NFCMiFareTag, data:Data, completion: @escaping (_ data: Data)->()) {
        print("COMMAND TO CARD => "+data.hexEncodedString())
        tag.sendMiFareCommand(commandPacket: data, completionHandler: { (data:Data, error:Error?) in
            if(error != nil) {
                print("COMMAND ERROR : "+error!.localizedDescription)
                return
            }
            print("CARD RESPONSE <= "+data.hexEncodedString())
            completion(data)
        })
    }
    
}

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }
    
    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return map { String(format: format, $0) }.joined()
    }
}
extension Double {
    // Rounds the double to decimal places value
    func rounded(toPlaces places:Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
