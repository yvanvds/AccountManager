using Google.Apis.Admin.Directory.directory_v1;
using Google.Apis.Auth.OAuth2;
using Google.Apis.Services;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Google
{
    public static class Connector
    {
        // only define scopes that you've given access for!
        static private string[] scopes = {
          DirectoryService.Scope.AdminDirectoryDomain,
          DirectoryService.Scope.AdminDirectoryGroup,
          DirectoryService.Scope.AdminDirectoryOrgunit,
          DirectoryService.Scope.AdminDirectoryUser
        };

        static internal DirectoryService service;

        internal static ILog Log;

        static internal string Domain;

        public static bool Init(string appName, string user, string domain, ILog log = null)
        {
            Domain = domain;
            Log = log;

            try
            {
                string secret = File.ReadAllText("client_secret.json");

                dynamic values = JsonConvert.DeserializeObject(secret);
                string key = values.private_key;
                string ID = values.client_id;
                string tokenURI = values.token_uri;

                return Init(appName, user, domain, key, ID, tokenURI, log);
            }
            catch (Exception e)
            {
                Log.AddError(Origin.Google, e.Message);
                return false;
            }

        }

        public static bool Init(string appName, string user, string domain, string key, string ID, string token, ILog log = null)
        {
            Domain = domain;
            Log = log;

            ServiceAccountCredential credential;

            try
            {

                credential = new ServiceAccountCredential(
                    new ServiceAccountCredential.Initializer(ID, token)
                    {
                        User = user,
                        Scopes = scopes
                    }.FromPrivateKey(key));

                service = new DirectoryService(new BaseClientService.Initializer()
                {
                    HttpClientInitializer = credential,
                    ApplicationName = appName,
                });

            }
            catch (Exception e)
            {
                Log.AddError(Origin.Google, e.Message);
                return false;
            }

            Log.AddMessage(Origin.Google, "Connection Suceeded");
            return true;
        }
    }
}
