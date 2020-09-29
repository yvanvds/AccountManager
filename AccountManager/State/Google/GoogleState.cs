using AccountApi;
using AccountManager.Utils;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

//namespace AccountManager.State.Google
//{
//    public class GoogleState : AbstractState
//    {
//        public ConfigValue<ConnectionState> Connection;
//        public ConfigValue<string> AppName;
//        public ConfigValue<string> AppDomain;
//        public ConfigValue<string> Admin;
//        public ConfigValue<string> ApiKey;
//        public ConfigValue<string> ApiID;
//        public ConfigValue<string> ApiToken;

//        public GoogleAccounts Accounts = new GoogleAccounts();

//        public GoogleState()
//        {
//            Connection = new ConfigValue<ConnectionState>("connectionTested", ConnectionState.Unknown, UpdateObservers);
//            AppName = new ConfigValue<string>("appName", "", UpdateObservers, UpdateConnectionState);
//            AppDomain = new ConfigValue<string>("appDomain", "", UpdateObservers, UpdateConnectionState);
//            Admin = new ConfigValue<string>("admin", "", UpdateObservers, UpdateConnectionState);
//            ApiKey = new ConfigValue<string>("apiKey", "", UpdateObservers, UpdateConnectionState);
//            ApiID = new ConfigValue<string>("apiID", "", UpdateObservers, UpdateConnectionState);
//            ApiToken = new ConfigValue<string>("apiToken", "", UpdateObservers, UpdateConnectionState);
//        }

//        public override void LoadConfig(JObject obj)
//        {
//            Connection.Load(obj);
//            AppName.Load(obj);
//            AppDomain.Load(obj);
//            Admin.Load(obj);
//            ApiKey.Load(obj);
//            ApiID.Load(obj);
//            ApiToken.Load(obj);
//        }

//        public override async Task LoadContent()
//        {
//            Connect();
//            await Accounts.Load();
//        }

//        public override void LoadLocalContent()
//        {
//            Accounts.LoadFromJson();
//        }

//        public override JObject SaveConfig()
//        {
//            JObject result = new JObject();

//            Connection.Save(ref result);
//            AppName.Save(ref result);
//            AppDomain.Save(ref result);
//            Admin.Save(ref result);
//            ApiKey.Save(ref result);
//            ApiID.Save(ref result);
//            ApiToken.Save(ref result);

//            return result;
//        }

//        public override void SaveContent()
//        {
//            Accounts.SaveToJson();
//        }

//        public void UpdateConnectionState(ConnectionState state)
//        {
//            Connection.Value = state;
//        }

//        public void SetSecret(string secret)
//        {
//            try
//            {
//                dynamic values = JsonConvert.DeserializeObject(secret);
//                ApiKey.Value = values.private_key;
//                ApiID.Value = values.client_id;
//                ApiToken.Value = values.token_uri;
//            }
//            catch (Exception e)
//            {
//                MainWindow.Instance.Log.AddError(Origin.Google, e.Message);
//            }
//        }

//        public bool IsSecretSet
//        {
//            get
//            {
//                if (ApiKey.Value == string.Empty) return false;
//                if (ApiToken.Value == string.Empty) return false;
//                if (ApiID.Value == string.Empty) return false;
//                return true;
//            }
//        }

//        public void Connect()
//        {
//            Connection.Value = ConnectionState.InProgress;
//            bool result = AccountApi.Google.Connector.Init(
//                AppName.Value,
//                Admin.Value,
//                AppDomain.Value,
//                ApiKey.Value,
//                ApiID.Value,
//                ApiToken.Value,
//                MainWindow.Instance.Log
//            );
//            if (result)
//            {
//                Connection.Value = ConnectionState.OK;
//            }
//            else
//            {
//                Connection.Value = ConnectionState.Failed;
//            }
//        }
//    }
//}
