using AbstractAccountApi;
using AccountApi;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        private DateTime lastGoogleAccountSync;
        public DateTime LastGoogleAccountSync => lastGoogleAccountSync;

        const string googleAccountsFile = "googleAccounts.json";

        private void LoadGoogleConfig(JObject obj)
        {
            googleAppName = obj.ContainsKey("appName") ? obj["appName"].ToString() : "";
            googleAppDomain = obj.ContainsKey("appDomain") ? obj["appDomain"].ToString() : "";
            googleAdmin = obj.ContainsKey("admin") ? obj["admin"].ToString() : "";
            googleApiKey = obj.ContainsKey("apiKey") ? obj["apiKey"].ToString() : "";
            googleApiID = obj.ContainsKey("apiID") ? obj["apiID"].ToString() : "";
            googleApiToken = obj.ContainsKey("apiToken") ? obj["apiToken"].ToString() : "";
        }

        private JObject SaveGoogleConfig()
        {
            JObject result = new JObject
            {
                ["appName"] = googleAppName,
                ["appDomain"] = googleAppDomain,
                ["admin"] = googleAdmin,
                ["apiKey"] = googleApiKey,
                ["apiID"] = googleApiID,
                ["apiToken"] = googleApiToken
            };
            return result;
        }

        private void LoadGoogleFileContent()
        {
            SetGoogleCredentials();

            var accountLocation = Path.Combine(appFolder, googleAccountsFile);
            if(File.Exists(accountLocation))
            {
                string content = File.ReadAllText(accountLocation);
                var newObj = JObject.Parse(content);
                AccountApi.Google.AccountManager.FromJson(newObj);
                lastGoogleAccountSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }
        }

        private string googleAppName;

        public string GoogleAppName
        {
            get { return googleAppName; }
            set
            {
                googleAppName = value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleAppDomain;

        public string GoogleAppDomain
        {
            get { return googleAppDomain; }
            set
            {
                googleAppDomain = value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleAdmin;

        public string GoogleAdmin
        {
            get { return googleAdmin; }
            set
            {
                googleAdmin =  value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleApiKey = "";
        private string googleApiID = "";
        private string googleApiToken = "";

        public void SetGoogleSecret(string secret)
        {
            try
            {
                dynamic values = JsonConvert.DeserializeObject(secret);
                googleApiKey = values.private_key;
                googleApiID = values.client_id;
                googleApiToken = values.token_uri;
                GoogleConnectionTested = ConfigState.Unknown;
            }
            catch (Exception e)
            {
                MainWindow.Instance.Log.AddError(Origin.Google, e.Message);
            }
        }

        public bool IsGoogleSecretSet
        {
            get
            {
                if (googleApiKey == string.Empty) return false;
                if (googleApiToken == string.Empty) return false;
                if (googleApiID == string.Empty) return false;
                return true;
            }
        }

        private ConfigState googleConnectionTested;

        public ConfigState GoogleConnectionTested
        {
            get { return googleConnectionTested; }
            set
            {
                googleConnectionTested = value;
                ConfigChanged = true;
            }
        }

        public void SetGoogleCredentials()
        {
            googleConnectionTested = ConfigState.InProgress;
            bool result = AccountApi.Google.Connector.Init(
                googleAppName, 
                googleAdmin, 
                googleAppDomain, 
                googleApiKey, 
                googleApiID, 
                googleApiToken, 
                MainWindow.Instance.Log
            );
            if(result)
            {
                googleConnectionTested = ConfigState.OK;
            } else
            {
                googleConnectionTested = ConfigState.Failed;
            }
        }

        public async Task ReloadGoogleAccounts()
        {
            AccountApi.Google.AccountManager.ClearAll();
            await AccountApi.Google.AccountManager.ReloadAll();
            lastGoogleAccountSync = DateTime.Now;
            SaveGoogleAccountsToFile();
        }

        public void SaveGoogleAccountsToFile()
        {
            var json = AccountApi.Google.AccountManager.ToJson();
            json["lastSync"] = LastGoogleAccountSync;
            var location = Path.Combine(appFolder, googleAccountsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
