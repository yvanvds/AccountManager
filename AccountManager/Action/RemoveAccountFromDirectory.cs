using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class RemoveAccountFromDirectory : AccountAction
    {
        public RemoveAccountFromDirectory() : base(
            AccountActionType.RemoveFromDirectory,
            "Verwijder Active Directory Account",
            "Dit account bestaat enkel in Active Directory. Waarschijnlijk kan het verwijderd worden.",
            true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            await AccountApi.Directory.AccountManager.DeleteStudent(linkedAccount.directoryAccount);
        }
    }
}
