using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class DontImportFromWisa : AccountAction
    {
        public DontImportFromWisa() : base(
            "Negeer Wisa Account",
            "Als dit personeelslid niet meer in actieve dienst is, dan kan je dit account negeren.",
            true
            )
        { }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            IRule rule = State.App.Instance.Wisa.AddimportRule(AccountApi.Rule.WI_DontImportUser);
            rule.SetConfig(0, account.Wisa.Account.CODE);
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Wisa.Exists && !account.Smartschool.Exists)
            {
                account.Actions.Add(new DontImportFromWisa());
            }
        }
    }
}
