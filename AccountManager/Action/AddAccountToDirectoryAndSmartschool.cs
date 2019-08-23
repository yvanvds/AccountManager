using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddAccountToDirectoryAndSmartschool : AccountAction
    {
        public AddAccountToDirectoryAndSmartschool() : base(
            AccountActionType.AddToDirectoryAndSmartschool,
            "Maak een Nieuw Account",
            "Voeg een account toe aan Active Directory en Smartschool.",
            true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            var wisa = linkedAccount.wisaAccount;
            var directory = await AccountApi.Directory.AccountManager.Create(wisa.FirstName, wisa.Name, wisa.WisaID, AccountRole.Student, wisa.ClassGroup);

            if (directory != null)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added account for " + wisa.FullName);
                await AddAccountToSmartschool.Add(linkedAccount, wisa, directory);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Failed to add " + wisa.FullName);
            }
        } 
    }
}
