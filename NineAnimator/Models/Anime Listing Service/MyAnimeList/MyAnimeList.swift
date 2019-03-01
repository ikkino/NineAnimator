//
//  This file is part of the NineAnimator project.
//
//  Copyright © 2018-2019 Marcus Zhou. All rights reserved.
//
//  NineAnimator is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  NineAnimator is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with NineAnimator.  If not, see <http://www.gnu.org/licenses/>.
//

import Alamofire
import Foundation

class MyAnimeList: BaseListingService, ListingService {
    var name: String { return "MyAnimeList.net" }
    
    override var identifier: String { return "com.marcuszhou.nineanimator.service.mal" }
    
    /// MAL api endpoint
    let endpoint = URL(string: "https://api.myanimelist.net/v0.21")!
}

// MARK: - Capabilities
extension MyAnimeList {
    var isCapableOfListingAnimeInformation: Bool { return false }
    
    var isCapableOfPersistingAnimeState: Bool { return false }
    
    var isCapableOfRetrievingAnimeState: Bool { return false }
}

// MARK: - Authentications
extension MyAnimeList {
    private var accessToken: String? {
        get { return persistedProperties["access_token"] as? String }
        set { persistedProperties["access_token"] = newValue }
    }
    
    private var accessTokenExpirationDate: Date {
        get { return (persistedProperties["access_token_expiration"] as? Date) ?? .distantPast }
        set { return persistedProperties["access_token_expiration"] = newValue }
    }
    
    private var refreshToken: String? {
        get { return persistedProperties["restore_token"] as? String }
        set { persistedProperties["restore_token"] = newValue }
    }
    
    /// MAL Android app's client identifier
    private var clientIdentifier: String { return "6114d00ca681b7701d1e15fe11a4987e" }
    
    var didSetup: Bool { return accessToken != nil }
    
    var didExpire: Bool { return accessTokenExpirationDate.timeIntervalSinceNow < 0 }
    
    func deauthenticate() {
        Log.info("[MyAnimeList] Removing credentials")
        accessToken = nil
        refreshToken = nil
        accessTokenExpirationDate = .distantPast
    }
    
    /// Authenticate the session with username and password
    func authenticate(withUser user: String, password: String) -> NineAnimatorPromise<Void> {
        return NineAnimatorPromise.firstly {
            [clientIdentifier] in
            var formBuilder = URLComponents()
            formBuilder.queryItems = [
                .init(name: "client_id", value: clientIdentifier),
                .init(name: "grant_type", value: "password"),
                .init(name: "password", value: password),
                .init(name: "username", value: user)
            ]
            return try some(formBuilder.percentEncodedQuery?.data(using: .utf8), or: .urlError)
        } .thenPromise {
            [endpoint] encodedForm in
            // Send refresh request with refresh token
            self.request(endpoint.appendingPathComponent("/auth/token"), method: .post, data: encodedForm, headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
                "Content-Length": String(encodedForm.count)
            ])
        } .then {
            (responseData: Data) in
            try JSONSerialization.jsonObject(with: responseData, options: []) as? NSDictionary
        } .thenPromise { self.authenticate(withResponseObject: $0) }
    }
    
    /// Refresh the expired token with the stored refresh token
    private func authenticateWithRefreshToken() -> NineAnimatorPromise<Void> {
        return NineAnimatorPromise.firstly {
            self.refreshToken // Retrieve the refresh token
        } .thenPromise {
            [clientIdentifier] token in
            let encodedForm: Data = try {
                var formBuilder = URLComponents()
                formBuilder.queryItems = [
                    .init(name: "client_id", value: clientIdentifier),
                    .init(name: "grant_type", value: "refresh_token"),
                    .init(name: "refresh_token", value: token)
                ]
                return try some(formBuilder.percentEncodedQuery?.data(using: .utf8), or: .urlError)
            }()
            
            Log.info("[MyAnimeList] Re-authenticating the session with refresh token")
            
            // Send refresh request with refresh token
            return self.request(URL(string: "https://myanimelist.net/v1/oauth2/token")!, method: .post, data: encodedForm, headers: [
                ":authority": "myanimelist.net",
                "Content-Type": "application/x-www-form-urlencoded",
                "Content-Length": String(encodedForm.count)
            ])
        } .then {
            (responseData: Data) in
            try JSONSerialization.jsonObject(with: responseData, options: []) as? NSDictionary
        } .thenPromise { self.authenticate(withResponseObject: $0) }
    }
    
    /// Authenticate the session with the response from MyAnimeList
    private func authenticate(withResponseObject responseObject: NSDictionary) -> NineAnimatorPromise<Void> {
        return .firstly {
            // If the error entry is present in the response object
            if let error = responseObject["error"] as? String,
                let message = responseObject["message"] as? String {
                if error == "invalid_grant" { // Invalid credentials
                    throw NineAnimatorError.authenticationRequiredError(message, nil)
                } else { throw NineAnimatorError.responseError(message) }
            }
            
            let token = try some(responseObject["access_token"] as? String, or: .decodeError)
            let expirationAfter = try some(responseObject["expires_in"] as? Int, or: .decodeError)
            let refreshToken = try some(responseObject["refresh_token"] as? String, or: .decodeError)
            let tokenType = try some(responseObject["token_type"] as? String, or: .decodeError)
            
            // Check token type
            guard tokenType == "Bearer" else {
                throw NineAnimatorError.responseError("The server returned an invalid token type")
            }
            
            // Store tokens
            self.accessToken = token
            self.refreshToken = refreshToken
            self.accessTokenExpirationDate = Date().addingTimeInterval(TimeInterval(expirationAfter))
            
            Log.info("[MyAnimeList] Session authenticated")
            
            // Return success
            return ()
        }
    }
}

// MARK: - Unimplemented
extension MyAnimeList {
    func update(_ reference: ListingAnimeReference, newState: ListingAnimeTrackingState) { }
    
    func update(_ reference: ListingAnimeReference, didComplete episode: EpisodeLink) { }
    
    func listingAnime(from reference: ListingAnimeReference) -> NineAnimatorPromise<ListingAnimeInformation> {
        return .fail(.unknownError)
    }
    
    func collections() -> NineAnimatorPromise<[ListingAnimeCollection]> {
        return .fail(.unknownError)
    }
}

// MARK: - Request Helper
extension MyAnimeList {
    struct APIResponse {
        let raw: NSDictionary
        let data: [NSDictionary]
        
        init(_ raw: NSDictionary) throws {
            self.raw = raw
            self.data = try some(
                raw["data"] as? [NSDictionary],
                or: .responseError("No data found in the response object")
            )
        }
    }
    
    func apiRequest(_ path: String, query: [String: CustomStringConvertible] = [:]) -> NineAnimatorPromise<APIResponse> {
        var firstPromise: NineAnimatorPromise<Void> = .success(())
        if didSetup && didExpire {
            // Refresh the token first if needed
            firstPromise = authenticateWithRefreshToken()
        }
        return firstPromise.then {
            [endpoint, clientIdentifier] () -> (URL, [String: String]) in
            var url = endpoint.appendingPathComponent(path)
            let headers = [ "X-MAL-Client-ID": clientIdentifier ]
            
            // Build GET parameters
            if !query.isEmpty,
                var urlBuilder = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                urlBuilder.queryItems = query.map { .init(name: $0.key, value: $0.value.description) }
                url = try some(
                    urlBuilder.url,
                    or: .urlError
                )
            }
            
            // Return the request parameters
            return (url, headers)
        } .thenPromise {
            url, headers in self.request(url, method: .get, data: nil, headers: headers)
        } .then {
            try JSONSerialization.jsonObject(with: $0, options: []) as? NSDictionary
        } .then {
            response in
            // If an error is reported
            if response["error"] != nil,
                let errorMessage = response["message"] as? String {
                throw NineAnimatorError.responseError(errorMessage)
            }
            
            // Construct the APIResponse
            return try APIResponse(response)
        }
    }
}
