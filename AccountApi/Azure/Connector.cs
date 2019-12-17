using Microsoft.Graph;
using Microsoft.Identity.Client;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Interop;

namespace AccountApi.Azure
{
    public sealed class Connector : IAuthenticationProvider
    {
        private static Connector instance = new Connector();
        private Connector() { }
        public static Connector Instance { get { return instance; } }

        public void Create(string clientID, string tenantID, System.Windows.Window parentWindow, ILog log = null)
        {
            this.log = log;
            this.parentWindow = parentWindow;

            clientApp = PublicClientApplicationBuilder.Create(clientID)
                .WithAuthority(AzureCloudInstance.AzurePublic, tenantID)
                .WithDefaultRedirectUri()
                .Build();
            TokenCacheHelper.EnableSerialization(clientApp.UserTokenCache);
            
            directory = new GraphServiceClient(this);
        }

        private async Task<string> getAccessToken()
        {
            var accounts = await clientApp.GetAccountsAsync();
            var firstAccount = accounts.FirstOrDefault();
            AuthenticationResult authResult = null;

            try
            {
                authResult = await clientApp.AcquireTokenSilent(scopes, firstAccount).ExecuteAsync();
            }
            catch(MsalUiRequiredException)
            {
                // A MsalUiRequiredException happened on AcquireTokenSilent. 
                // This indicates you need to call AcquireTokenInteractive to acquire a token

                try
                {
                    authResult = await clientApp.AcquireTokenInteractive(scopes)
                        .WithAccount(accounts.FirstOrDefault())
                        .WithParentActivityOrWindow(new WindowInteropHelper(parentWindow).Handle)
                        .WithPrompt(Microsoft.Identity.Client.Prompt.SelectAccount)
                        .ExecuteAsync();
                }
                catch(MsalException msalex)
                {
                    RegisterError($"Error Acquiring Token:{msalex.Message}");
                }
            }
            catch(Exception ex)
            {
                RegisterError($"Error Acquiring Token Silently:{ex.Message}");
                return null;
            }

            if (authResult != null)
            {
                return authResult.AccessToken;
            }
            else return null;
        }


        public async Task AuthenticateRequestAsync(HttpRequestMessage request)
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", await getAccessToken());
        }

        public void RegisterError(string message)
        {
            if (log != null)
            {
                log.AddError(Origin.Azure, message);
            }
        }

        public void RegisterMessage(string message)
        {
            if (log != null)
            {
                log.AddMessage(Origin.Azure, message);
            }
        }

        private static IPublicClientApplication clientApp;
        private string[] scopes = new string[] { "User.ReadWrite.All" };
        
        System.Windows.Window parentWindow = null;

        private ILog log = null;

        private GraphServiceClient directory;
        public GraphServiceClient Directory => directory;
    }
}
