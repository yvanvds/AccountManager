using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifyAccountID : AccountAction
    {
        public ModifyAccountID() : base(AccountActionType.ModifyAccountID,
        "Wijzig het Intern Nummber in Smartschool",
        "Het intern nummer hoort gelijk te zijn aan de Wisa ID van de leerling",
        true, true) {
        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.smartschoolAccount.AccountID = linkedAccount.wisaAccount.WisaID;
            await AccountApi.Smartschool.AccountManager.ChangeAccountID(linkedAccount.smartschoolAccount);
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            if (account.wisaAccount.WisaID != account.smartschoolAccount.AccountID)
            {
                account.SmartschoolStatusIcon = "AlertCircleOutline";
                account.SmartschoolStatusColor = "Orange";
                account.Actions.Add(new ModifyAccountID());
                account.AccountOK = false;
            }
        }
    }

    
}
