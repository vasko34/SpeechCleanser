//
//  SceneDelegate.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 28.09.25.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        
        let window = UIWindow(windowScene: windowScene)
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let rootController: UIViewController
        
        if let viewController = storyboard.instantiateInitialViewController() as? ViewController {
            rootController = UINavigationController(rootViewController: viewController)
        } else {
            rootController = UINavigationController(rootViewController: ViewController())
        }
        
        window.rootViewController = rootController
        window.makeKeyAndVisible()
        self.window = window
        print("[SceneDelegate] sceneWillConnectTo: Window configured")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        print("[SceneDelegate] sceneDidDisconnect: Scene disconnected")
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        print("[SceneDelegate] sceneDidBecomeActive: Scene active")
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        print("[SceneDelegate] sceneWillResignActive: Scene resigning active")
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        print("[SceneDelegate] sceneWillEnterForeground: Entering foreground")
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        print("[SceneDelegate] sceneDidEnterBackground: Entered background")
    }
}

