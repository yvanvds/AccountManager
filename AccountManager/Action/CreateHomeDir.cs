using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class CreateHomeDir : AccountAction
    {
        public CreateHomeDir() : base(AccountActionType.CreateHomedir,
            "Maak de Home Directory opnieuw aan",
            "Dit maakt een home directory op de fileserver voor dit account, en stelt de toegangsrechten in. Deze actie kan een tijd duren.",
            true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            MainWindow.Instance.Log.AddMessage(Origin.Directory, "Adding home for " + linkedAccount.directoryAccount.FullName);
            bool success = await AccountApi.Directory.AccountManager.CreateHomeDir(linkedAccount.directoryAccount);
            if (success)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added home at " + linkedAccount.directoryAccount.HomeDirectory);
            } else
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Failed to add home at " + linkedAccount.directoryAccount.HomeDirectory);
            }
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            if (State.App.Instance.AD.CheckHomeDirs.Value == false) return;
            if (account.directoryAccount.HomeDirectory.Length > 0 && !System.IO.Directory.Exists(account.directoryAccount.HomeDirectory))
            {
                account.DirectoryStatusIcon = "AlertCircleOutline";
                account.DirectoryStatusColor = "Orange";
                account.Actions.Add(new CreateHomeDir());
                account.AccountOK = false;
            }
        }
    }
}
