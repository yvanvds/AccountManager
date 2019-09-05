using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class UnregisterSmartschoolAccount : AccountAction
    {
        public UnregisterSmartschoolAccount() : base(AccountActionType.DisableInSmartschool,
            "Schrijf de leerling uit in smartschool",
            "De leerling wordt uitgeschreven zonder het account te verwijderen", true)
        { }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Smartschool.AccountManager.UnregisterStudent(linkedAccount.smartschoolAccount, deletionDate);
        }
    }
}
